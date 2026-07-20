import { createHash, randomUUID } from "node:crypto";
import { chmod, lstat, mkdir, open, readFile, rename, unlink } from "node:fs/promises";
import path from "node:path";

import { LinearCommentCollisionError, LinearUploadError } from "./linear.mjs";
import { verifyProofManifest } from "./manifest.mjs";
import { safeArtifactPath } from "./security.mjs";

const LOCK_FILE_SYSTEM = { lstat, open, unlink };
const JOURNAL_FILE_SYSTEM = { lstat, open, readFile, rename, unlink };

export class PublicationError extends Error {
  constructor(publicCode, publicMessage, options = {}) {
    super(publicMessage, options);
    this.name = "PublicationError";
    this.publicCode = publicCode;
    this.publicMessage = publicMessage;
  }
}

function publicationError(code, message, cause) {
  return new PublicationError(code, message, cause ? { cause } : {});
}

function commitUnknownFailure(message, cause) {
  const error = new Error(message, cause ? { cause } : {});
  error.commitUnknown = true;
  return error;
}

function validExternalId(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 256;
}

function operationKey(issueId, manifest, reviewStateId) {
  return createHash("sha256")
    .update(`${issueId}\0${manifest.manifest_sha256}\0${reviewStateId}`)
    .digest("hex");
}

async function loadJournal(journalPath, fileSystem) {
  try {
    const metadata = await fileSystem.lstat(journalPath);
    if (!metadata.isFile() || metadata.isSymbolicLink() || (metadata.mode & 0o077) !== 0) {
      throw new Error("publication journal file is unsafe");
    }
    return JSON.parse(await fileSystem.readFile(journalPath, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

async function removeTemporaryJournal(temporary, fileSystem) {
  try {
    await fileSystem.unlink(temporary);
    return null;
  } catch (error) {
    return error.code === "ENOENT" ? null : error;
  }
}

function combinedFailure(primary, cleanup, message) {
  if (primary && cleanup) return new AggregateError([primary, cleanup], message);
  return primary ?? cleanup;
}

async function storeJournal(journalPath, journal, fileSystem) {
  const temporary = `${journalPath}.${process.pid}.${randomUUID()}.tmp`;
  const handle = await fileSystem.open(temporary, "wx", 0o600);
  let writeFailure = null;
  try {
    await handle.writeFile(`${JSON.stringify(journal, null, 2)}\n`, "utf8");
    await handle.sync();
  } catch (error) {
    writeFailure = error;
  }

  let fileCloseFailure = null;
  try {
    await handle.close();
  } catch (error) {
    fileCloseFailure = error;
  }

  const fileFailure = combinedFailure(
    writeFailure,
    fileCloseFailure,
    "publication journal write and file cleanup both failed",
  );
  if (fileFailure) {
    const cleanupFailure = await removeTemporaryJournal(temporary, fileSystem);
    throw combinedFailure(
      fileFailure,
      cleanupFailure,
      "publication journal write and temporary cleanup both failed",
    );
  }

  try {
    await fileSystem.rename(temporary, journalPath);
  } catch (error) {
    const cleanupFailure = await removeTemporaryJournal(temporary, fileSystem);
    throw combinedFailure(
      error,
      cleanupFailure,
      "publication journal rename and temporary cleanup both failed",
    );
  }

  const directory = await fileSystem.open(path.dirname(journalPath), "r");
  let directorySyncFailure = null;
  try {
    await directory.sync();
  } catch (error) {
    directorySyncFailure = error;
  }

  let directoryCloseFailure = null;
  try {
    await directory.close();
  } catch (error) {
    directoryCloseFailure = error;
  }

  if (directorySyncFailure) {
    throw combinedFailure(
      directorySyncFailure,
      directoryCloseFailure,
      "publication journal directory sync and cleanup both failed",
    );
  }

  // Once directory sync succeeds, the journal stage is durable. A directory
  // handle-close failure is a resource warning and must not rewrite that known
  // outcome as an ambiguous external side effect.
  return directoryCloseFailure ? { cleanup_warning: "journal_directory_close_failed" } : {};
}

const JOURNAL_STAGES = new Set([
  "prepared",
  "uploading",
  "upload_unknown",
  "uploaded",
  "comment_unknown",
  "commented",
  "transition_unknown",
  "published",
]);

function validAssetUrl(value) {
  try {
    const url = new URL(value);
    return (
      url.protocol === "https:" &&
      url.hostname === "uploads.linear.app" &&
      url.port === "" &&
      !url.username &&
      !url.password
    );
  } catch {
    return false;
  }
}

function validateJournal(journal, expected) {
  if (
    !journal ||
    typeof journal !== "object" ||
    Array.isArray(journal) ||
    journal.schema_version !== 1 ||
    journal.operation_key !== expected.key ||
    journal.issue_id !== expected.issueId ||
    journal.manifest_sha256 !== expected.manifestSha256 ||
    journal.review_state_id !== expected.reviewStateId ||
    !JOURNAL_STAGES.has(journal.stage)
  ) {
    throw new Error("publication journal is invalid");
  }
  if (
    ["uploaded", "comment_unknown", "commented", "transition_unknown", "published"].includes(journal.stage) &&
    !validAssetUrl(journal.asset_url)
  ) {
    throw new Error("publication journal is invalid");
  }
  if (
    ["commented", "transition_unknown", "published"].includes(journal.stage) &&
    (typeof journal.comment_id !== "string" || journal.comment_id.length === 0 || journal.comment_id.length > 256)
  ) {
    throw new Error("publication journal is invalid");
  }
}

async function storeValidatedJournal(journalPath, journal, expected, fileSystem) {
  validateJournal(journal, expected);
  return storeJournal(journalPath, journal, fileSystem);
}

function commentBody(marker, manifest, assetUrl) {
  const passed = manifest.steps.filter((step) => step.passed).length;
  const destination = new URL(assetUrl).href;
  return [
    "## Bethoven visual proof",
    "",
    `![Visual proof for ${manifest.issue_id}](<${destination}>)`,
    "",
    `Verified **${passed}/${manifest.steps.length}** browser steps on commit \`${manifest.repository.head.slice(0, 12)}\`.`,
    `Manifest: \`${manifest.manifest_sha256}\``,
    `Proof operation: \`${marker}\``,
  ].join("\n");
}

function sameFileIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

async function cleanupPublicationLock(lockPath, lock, identity, fileSystem) {
  let closeFailure = null;
  try {
    await lock.close();
  } catch (error) {
    closeFailure = error;
  }

  let pathFailure = null;
  if (!identity) {
    pathFailure = new Error("publication lock identity is unavailable");
  } else {
    try {
      const current = await fileSystem.lstat(lockPath, { bigint: true });
      if (!current.isFile() || current.isSymbolicLink() || !sameFileIdentity(current, identity)) {
        throw new Error("publication lock path identity changed");
      }
      await fileSystem.unlink(lockPath);
    } catch (error) {
      pathFailure = error;
    }
  }

  return { closeFailure, pathFailure };
}

function finishPublication(result, primaryFailure, cleanup) {
  if (cleanup.pathFailure) {
    const failures = primaryFailure
      ? [primaryFailure, cleanup.pathFailure]
      : [cleanup.pathFailure];
    if (cleanup.closeFailure) failures.push(cleanup.closeFailure);
    throw publicationError(
      "publication_lock_cleanup_required",
      "publication lock cleanup failed and requires operator intervention",
      new AggregateError(failures, "publication and lock cleanup did not both complete"),
    );
  }

  if (primaryFailure) {
    if (cleanup.closeFailure) {
      const combined = new AggregateError(
        [primaryFailure, cleanup.closeFailure],
        "publication failed and the lock handle also failed to close",
      );
      if (primaryFailure instanceof PublicationError) {
        throw publicationError(
          primaryFailure.publicCode,
          primaryFailure.publicMessage,
          combined,
        );
      }
      throw combined;
    }
    throw primaryFailure;
  }

  if (cleanup.closeFailure) {
    return {
      ...result,
      cleanup_warnings: [
        ...new Set([...(result.cleanup_warnings ?? []), "lock_handle_close_failed"]),
      ],
    };
  }
  return result;
}

async function runLockedPublication(input, lock, key, marker, journalPath, journalFileSystem) {
  try {
    await lock.writeFile(`${process.pid} ${new Date().toISOString()}\n`, "utf8");
    await lock.sync();
  } catch (error) {
    throw publicationError("publication_lock_failed", "publication lock initialization failed", error);
  }

  const expected = {
    key,
    issueId: input.issueId,
    manifestSha256: input.manifest.manifest_sha256,
    reviewStateId: input.reviewStateId,
  };
  const cleanupWarnings = new Set();
  const persistJournal = async (value) => {
    const outcome = await storeValidatedJournal(
      journalPath,
      value,
      expected,
      journalFileSystem,
    );
    if (outcome.cleanup_warning) cleanupWarnings.add(outcome.cleanup_warning);
  };
  const failAfterPersist = async (value, code, message, primaryFailure) => {
    let persistenceFailure = null;
    try {
      await persistJournal(value);
    } catch (error) {
      persistenceFailure = error;
    }
    throw publicationError(
      code,
      message,
      combinedFailure(
        primaryFailure,
        persistenceFailure,
        "external outcome and publication-journal persistence both failed",
      ),
    );
  };
  const publicationResult = (status, value) => {
    const result = { status, journal: value };
    if (cleanupWarnings.size > 0) result.cleanup_warnings = [...cleanupWarnings];
    return result;
  };
  let journal = await loadJournal(journalPath, journalFileSystem);

  if (!journal) {
    journal = {
      schema_version: 1,
      operation_key: key,
      issue_id: input.issueId,
      manifest_sha256: input.manifest.manifest_sha256,
      review_state_id: input.reviewStateId,
      stage: "prepared",
    };
    await persistJournal(journal);
  }

  validateJournal(journal, expected);
  if (journal.stage === "published") return publicationResult("published", journal);
  if (journal.stage === "uploading") {
    journal = { ...journal, stage: "upload_unknown" };
    await persistJournal(journal);
  }
  if (journal.stage === "upload_unknown") {
    throw publicationError(
      "upload_outcome_unknown",
      "upload commit outcome is unknown and requires operator reconciliation",
    );
  }

  if (journal.stage === "prepared") {
    const video = input.manifest.artifacts.find((artifact) => artifact.kind === "video");
    if (!video) throw new Error("proof manifest has no video artifact");
    const absolutePath = await safeArtifactPath(input.runRoot, video.path);
    journal = { ...journal, stage: "uploading" };
    await persistJournal(journal);
    try {
      const uploaded = await input.adapter.uploadArtifact({ ...video, absolutePath });
      journal = { ...journal, stage: "uploaded", asset_url: uploaded.assetUrl };
      await persistJournal(journal);
    } catch (error) {
      if (error instanceof LinearUploadError && error.putAttempted === false) {
        journal = { ...journal, stage: "prepared" };
        await failAfterPersist(
          journal,
          "upload_preflight_failed",
          "proof upload preflight failed; correct the packet or provider response and retry",
          error,
        );
      }
      journal = { ...journal, stage: "upload_unknown" };
      await failAfterPersist(
        journal,
        "upload_outcome_unknown",
        "upload commit outcome is unknown and requires operator reconciliation",
        error,
      );
    }
  }

  if (journal.stage === "uploaded" || journal.stage === "comment_unknown") {
    const expectedBody = commentBody(marker, input.manifest, journal.asset_url);
    let existing;
    try {
      existing = await input.adapter.findCommentByMarker(
        input.issueId,
        marker,
        expectedBody,
      );
    } catch (error) {
      if (error instanceof LinearCommentCollisionError) {
        throw publicationError(
          "comment_marker_collision",
          "proof comment marker collision requires operator review",
          error,
        );
      }
      throw publicationError(
        "linear_request_failed",
        "Linear proof-comment reconciliation failed; retry uses the durable journal",
        error,
      );
    }
    if (existing) {
      if (existing.body !== expectedBody) {
        throw publicationError(
          "comment_marker_collision",
          "proof comment marker collision requires operator review",
        );
      }
      if (!validExternalId(existing.id)) {
        throw publicationError(
          "linear_request_failed",
          "Linear proof-comment reconciliation returned an invalid comment identity",
        );
      }
      journal = { ...journal, stage: "commented", comment_id: existing.id };
      await persistJournal(journal);
    } else {
      let comment;
      try {
        comment = await input.adapter.createComment(input.issueId, expectedBody);
      } catch (error) {
        if (error.commitUnknown) {
          journal = { ...journal, stage: "comment_unknown" };
          await failAfterPersist(
            journal,
            "comment_outcome_unknown",
            "comment commit outcome unknown; retry to reconcile",
            error,
          );
        }
        throw publicationError(
          "linear_request_failed",
          "Linear proof-comment creation failed; retry uses marker reconciliation",
          error,
        );
      }
      if (comment?.body !== expectedBody || !validExternalId(comment?.id)) {
        const error = commitUnknownFailure(
          "Linear returned an invalid proof-comment mutation result",
        );
        journal = { ...journal, stage: "comment_unknown" };
        await failAfterPersist(
          journal,
          "comment_outcome_unknown",
          "comment commit outcome unknown; retry to reconcile",
          error,
        );
      }
      journal = { ...journal, stage: "commented", comment_id: comment.id };
      await persistJournal(journal);
    }
  }

  if (journal.stage === "transition_unknown" || journal.stage === "commented") {
    let alreadyInState;
    try {
      alreadyInState = await input.adapter.isIssueInState(input.issueId, input.reviewStateId);
    } catch (error) {
      throw publicationError(
        "linear_request_failed",
        "Linear review-state reconciliation failed; retry uses the durable journal",
        error,
      );
    }
    if (alreadyInState === true) {
      journal = { ...journal, stage: "published" };
      await persistJournal(journal);
      return publicationResult("published", journal);
    }
    journal = { ...journal, stage: "commented" };
    await persistJournal(journal);
  }

  if (journal.stage === "commented") {
    try {
      await input.adapter.transitionIssue(input.issueId, input.reviewStateId);
    } catch (error) {
      if (error.commitUnknown) {
        journal = { ...journal, stage: "transition_unknown" };
        await failAfterPersist(
          journal,
          "transition_outcome_unknown",
          "transition commit outcome unknown; retry to reconcile",
          error,
        );
      }
      throw publicationError(
        "linear_request_failed",
        "Linear review-state transition failed; retry first reconciles current state",
        error,
      );
    }
    let transitioned;
    try {
      transitioned = await input.adapter.isIssueInState(
        input.issueId,
        input.reviewStateId,
      );
    } catch (error) {
      journal = { ...journal, stage: "transition_unknown" };
      await failAfterPersist(
        journal,
        "transition_outcome_unknown",
        "transition commit outcome unknown; retry to reconcile",
        error,
      );
    }
    if (transitioned !== true) {
      journal = { ...journal, stage: "transition_unknown" };
      await failAfterPersist(
        journal,
        "transition_outcome_unknown",
        "transition commit outcome unknown; retry to reconcile",
        commitUnknownFailure("Linear did not confirm the requested review state"),
      );
    }
    journal = { ...journal, stage: "published" };
    await persistJournal(journal);
  }

  return publicationResult(
    journal.stage === "published" ? "published" : journal.stage,
    journal,
  );
}

export async function publishProof(input, options = {}) {
  try {
    await verifyProofManifest(input.runRoot, input.manifest);
  } catch (error) {
    throw publicationError("proof_packet_invalid", "proof packet validation failed", error);
  }
  if (input.manifest.status !== "passed") {
    throw publicationError("proof_packet_invalid", "only passed proof packets may be published");
  }
  if (input.issueId !== input.manifest.issue_id) {
    throw publicationError("publication_identity_mismatch", "publication issue identity mismatch");
  }
  if (
    typeof input.reviewStateId !== "string" ||
    !/^[A-Za-z0-9_-]{1,256}$/.test(input.reviewStateId)
  ) {
    throw publicationError(
      "publication_identity_mismatch",
      "publication review state identity mismatch",
    );
  }
  if (
    input.runId !== input.manifest.run_id ||
    input.expectedCommit !== input.manifest.repository.head ||
    input.acceptanceCriteriaSha256 !== input.manifest.bindings.acceptance_criteria_sha256 ||
    input.workflowSha256 !== input.manifest.bindings.workflow_sha256
  ) {
    throw publicationError("publication_identity_mismatch", "publication identity mismatch");
  }
  if (input.manifest.repository.dirty) {
    throw publicationError("proof_packet_invalid", "dirty proof packets may not be published");
  }

  await mkdir(input.journalRoot, { recursive: true, mode: 0o700 });
  const journalMetadata = await lstat(input.journalRoot);
  if (!journalMetadata.isDirectory() || journalMetadata.isSymbolicLink()) {
    throw new Error("publication journal root is unsafe");
  }
  await chmod(input.journalRoot, 0o700);
  const key = operationKey(input.issueId, input.manifest, input.reviewStateId);
  const marker = `bethoven-proof:${key}`;
  const journalPath = path.join(input.journalRoot, `${key}.json`);
  const lockPath = path.join(input.journalRoot, `${key}.lock`);
  const lockFileSystem = { ...LOCK_FILE_SYSTEM, ...(options.lockFileSystem ?? {}) };
  const journalFileSystem = {
    ...JOURNAL_FILE_SYSTEM,
    ...(options.journalFileSystem ?? {}),
  };
  let lock;
  try {
    lock = await lockFileSystem.open(lockPath, "wx", 0o600);
  } catch (error) {
    if (error.code === "EEXIST") {
      throw publicationError(
        "publication_locked",
        "publication is already active or requires stale-lock recovery",
      );
    }
    throw error;
  }

  let lockIdentity = null;
  let result;
  let primaryFailure = null;
  try {
    lockIdentity = await lock.stat({ bigint: true });
    if (!lockIdentity.isFile()) throw new Error("publication lock is not a regular file");
    result = await runLockedPublication(
      input,
      lock,
      key,
      marker,
      journalPath,
      journalFileSystem,
    );
  } catch (error) {
    primaryFailure = error;
  }

  const cleanup = await cleanupPublicationLock(
    lockPath,
    lock,
    lockIdentity,
    lockFileSystem,
  );
  return finishPublication(result, primaryFailure, cleanup);
}
