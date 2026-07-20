import { createHash, randomUUID } from "node:crypto";
import { chmod, lstat, mkdir, open, readFile, rename, unlink } from "node:fs/promises";
import path from "node:path";

import { verifyProofManifest } from "./manifest.mjs";
import { safeArtifactPath } from "./security.mjs";

function operationKey(issueId, manifest, reviewStateId) {
  return createHash("sha256")
    .update(`${issueId}\0${manifest.manifest_sha256}\0${reviewStateId}`)
    .digest("hex");
}

async function loadJournal(journalPath) {
  try {
    const metadata = await lstat(journalPath);
    if (!metadata.isFile() || metadata.isSymbolicLink() || (metadata.mode & 0o077) !== 0) {
      throw new Error("publication journal file is unsafe");
    }
    return JSON.parse(await readFile(journalPath, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

async function storeJournal(journalPath, journal) {
  const temporary = `${journalPath}.${process.pid}.${randomUUID()}.tmp`;
  const handle = await open(temporary, "wx", 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(journal, null, 2)}\n`, "utf8");
    await handle.sync();
  } finally {
    await handle.close();
  }
  try {
    await rename(temporary, journalPath);
    await chmod(journalPath, 0o600);
    const directory = await open(path.dirname(journalPath), "r");
    try {
      await directory.sync();
    } finally {
      await directory.close();
    }
  } finally {
    await unlink(temporary).catch(() => {});
  }
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
    return url.protocol === "https:" && url.hostname === "uploads.linear.app" && !url.username && !url.password;
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

function commentBody(marker, manifest, assetUrl) {
  const passed = manifest.steps.filter((step) => step.passed).length;
  return [
    "## Bethoven visual proof",
    "",
    `![Visual proof for ${manifest.issue_id}](${assetUrl})`,
    "",
    `Verified **${passed}/${manifest.steps.length}** browser steps on commit \`${manifest.repository.head.slice(0, 12)}\`.`,
    `Manifest: \`${manifest.manifest_sha256}\``,
    `Proof operation: \`${marker}\``,
  ].join("\n");
}

export async function publishProof(input) {
  await verifyProofManifest(input.runRoot, input.manifest);
  if (input.manifest.status !== "passed") throw new Error("only passed proof packets may be published");
  if (input.issueId !== input.manifest.issue_id) throw new Error("publication issue identity mismatch");
  if (
    input.runId !== input.manifest.run_id ||
    input.expectedCommit !== input.manifest.repository.head ||
    input.acceptanceCriteriaSha256 !== input.manifest.bindings.acceptance_criteria_sha256 ||
    input.workflowSha256 !== input.manifest.bindings.workflow_sha256
  ) {
    throw new Error("publication identity mismatch");
  }
  if (input.manifest.repository.dirty) throw new Error("dirty proof packets may not be published");

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
  let lock;
  try {
    lock = await open(lockPath, "wx", 0o600);
  } catch (error) {
    if (error.code === "EEXIST") {
      throw new Error("publication is already active or requires stale-lock recovery");
    }
    throw error;
  }
  await lock.writeFile(`${process.pid} ${new Date().toISOString()}\n`, "utf8");
  await lock.sync();

  try {
    let journal = await loadJournal(journalPath);

    if (!journal) {
      journal = {
        schema_version: 1,
        operation_key: key,
        issue_id: input.issueId,
        manifest_sha256: input.manifest.manifest_sha256,
        review_state_id: input.reviewStateId,
        stage: "prepared",
      };
      validateJournal(journal, {
        key,
        issueId: input.issueId,
        manifestSha256: input.manifest.manifest_sha256,
        reviewStateId: input.reviewStateId,
      });
      await storeJournal(journalPath, journal);
    }

    validateJournal(journal, {
      key,
      issueId: input.issueId,
      manifestSha256: input.manifest.manifest_sha256,
      reviewStateId: input.reviewStateId,
    });
    if (journal.stage === "published") return { status: "published", journal };
    if (journal.stage === "uploading") {
      journal = { ...journal, stage: "upload_unknown" };
      await storeJournal(journalPath, journal);
    }
    if (journal.stage === "upload_unknown") {
      throw new Error("upload commit outcome is unknown and requires operator reconciliation");
    }

    if (journal.stage === "prepared") {
      const video = input.manifest.artifacts.find((artifact) => artifact.kind === "video");
      if (!video) throw new Error("proof manifest has no video artifact");
      const absolutePath = await safeArtifactPath(input.runRoot, video.path);
      journal = { ...journal, stage: "uploading" };
      await storeJournal(journalPath, journal);
      try {
        const uploaded = await input.adapter.uploadArtifact({ ...video, absolutePath });
        journal = { ...journal, stage: "uploaded", asset_url: uploaded.assetUrl };
        await storeJournal(journalPath, journal);
      } catch (error) {
        journal = { ...journal, stage: "upload_unknown" };
        await storeJournal(journalPath, journal);
        throw error;
      }
    }

    if (journal.stage === "uploaded" || journal.stage === "comment_unknown") {
      const existing = await input.adapter.findCommentByMarker(input.issueId, marker);
      if (existing) {
        journal = { ...journal, stage: "commented", comment_id: existing.id };
        await storeJournal(journalPath, journal);
      } else {
        try {
          const comment = await input.adapter.createComment(
            input.issueId,
            commentBody(marker, input.manifest, journal.asset_url),
          );
          journal = { ...journal, stage: "commented", comment_id: comment.id };
          await storeJournal(journalPath, journal);
        } catch (error) {
          if (error.commitUnknown) {
            journal = { ...journal, stage: "comment_unknown" };
            await storeJournal(journalPath, journal);
            throw new Error("comment commit outcome unknown; retry to reconcile", { cause: error });
          }
          throw error;
        }
      }
    }

    if (journal.stage === "transition_unknown" || journal.stage === "commented") {
      if (await input.adapter.isIssueInState(input.issueId, input.reviewStateId)) {
        journal = { ...journal, stage: "published" };
        await storeJournal(journalPath, journal);
        return { status: "published", journal };
      }
      journal = { ...journal, stage: "commented" };
      await storeJournal(journalPath, journal);
    }

    if (journal.stage === "commented") {
      try {
        await input.adapter.transitionIssue(input.issueId, input.reviewStateId);
        journal = { ...journal, stage: "published" };
        await storeJournal(journalPath, journal);
      } catch (error) {
        if (error.commitUnknown) {
          journal = { ...journal, stage: "transition_unknown" };
          await storeJournal(journalPath, journal);
        }
        throw error;
      }
    }

    return { status: journal.stage === "published" ? "published" : journal.stage, journal };
  } finally {
    await lock.close();
    await unlink(lockPath).catch(() => {});
  }
}
