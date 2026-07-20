import assert from "node:assert/strict";
import {
  lstat,
  mkdtemp,
  open,
  readFile,
  readdir,
  rename,
  unlink,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { LinearCommentCollisionError, LinearProofAdapter } from "../src/linear.mjs";
import { createProofManifest } from "../src/manifest.mjs";
import { publishProof } from "../src/publisher.mjs";

function publicationInput(proof, journalRoot, remote) {
  return {
    adapter: remote,
    journalRoot,
    runRoot: proof.runRoot,
    issueId: "MT-893",
    runId: "run-001",
    expectedCommit: "a".repeat(40),
    acceptanceCriteriaSha256: "c".repeat(64),
    workflowSha256: "d".repeat(64),
    reviewStateId: "state-uuid",
    manifest: proof.manifest,
  };
}

function faultingLockFileSystem(phase) {
  const state = { failed: false, closed: false, unlinked: false };
  return {
    state,
    fileSystem: {
      async open(...args) {
        const handle = await open(...args);
        return {
          stat: (...values) => handle.stat(...values),
          async writeFile(...values) {
            if (phase === "write" && !state.failed) {
              state.failed = true;
              throw new Error("injected lock write failure");
            }
            return handle.writeFile(...values);
          },
          async sync() {
            if (phase === "sync" && !state.failed) {
              state.failed = true;
              throw new Error("injected lock sync failure");
            }
            return handle.sync();
          },
          async close() {
            state.closed = true;
            return handle.close();
          },
        };
      },
      async unlink(target) {
        state.unlinked = true;
        return unlink(target);
      },
    },
  };
}

async function packet({ status = "passed", dirty = false } = {}) {
  const runRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-packet-"));
  await writeFile(path.join(runRoot, "receipt.webm"), Buffer.from([0x1a, 0x45, 0xdf, 0xa3]));
  const manifest = await createProofManifest({
    runRoot,
    issueId: "MT-893",
    runId: "run-001",
    repository: {
      root: "/repo",
      head: "a".repeat(40),
      dirty,
      diff_sha256: dirty ? "b".repeat(64) : null,
    },
    target: "http://127.0.0.1:4317",
    browser: { name: "chromium", version: "1" },
    viewport: { width: 1280, height: 720 },
    startedAt: "2026-07-20T12:00:00.000Z",
    finishedAt: "2026-07-20T12:00:03.000Z",
    status,
    proofPlanSha256: "b".repeat(64),
    acceptanceCriteriaSha256: "c".repeat(64),
    workflowSha256: "d".repeat(64),
    steps: [{ ordinal: 1, action: "expect_text", passed: status === "passed", duration_ms: 12 }],
    diagnostics: { console_errors: [], failed_requests: [] },
    artifacts: [{ kind: "video", path: "receipt.webm", mediaType: "video/webm" }],
  });
  return { manifest, runRoot };
}

function adapter() {
  const state = {
    uploads: 0,
    comments: [],
    transitions: 0,
    throwAfterUpload: false,
    throwAfterComment: false,
    throwAfterTransition: false,
    uploadDelayMs: 0,
  };

  return {
    state,
    async uploadArtifact() {
      if (state.uploadDelayMs) {
        await new Promise((resolve) => setTimeout(resolve, state.uploadDelayMs));
      }
      state.uploads += 1;
      if (state.throwAfterUpload) throw new Error("upload response lost");
      return { assetUrl: "https://uploads.linear.app/proof.webm" };
    },
    async findCommentByMarker(_issueId, marker, expectedBody) {
      const matches = state.comments.filter((comment) => comment.body.includes(marker));
      if (matches.some((comment) => comment.body !== expectedBody)) {
        throw new Error("proof marker collision");
      }
      return matches.find((comment) => comment.body === expectedBody) ?? null;
    },
    async createComment(issueId, body) {
      const comment = { id: `comment-${state.comments.length + 1}`, issueId, body };
      state.comments.push(comment);
      if (state.throwAfterComment) {
        const error = new Error("response lost after commit");
        error.commitUnknown = true;
        throw error;
      }
      return comment;
    },
    async transitionIssue() {
      state.transitions += 1;
      if (state.throwAfterTransition) {
        const error = new Error("transition response lost");
        error.commitUnknown = true;
        throw error;
      }
      return { success: true };
    },
    async isIssueInState() {
      return state.transitions > 0;
    },
  };
}

async function publicationJournal(journalRoot) {
  const journalName = (await readdir(journalRoot)).find((entry) => entry.endsWith(".json"));
  assert.ok(journalName, "publication journal was not created");
  return JSON.parse(await readFile(path.join(journalRoot, journalName), "utf8"));
}

function closeFailingLockFileSystem() {
  const state = { unlinked: false };
  return {
    state,
    fileSystem: {
      async open(...args) {
        const handle = await open(...args);
        return {
          stat: (...values) => handle.stat(...values),
          writeFile: (...values) => handle.writeFile(...values),
          sync: (...values) => handle.sync(...values),
          async close() {
            await handle.close();
            throw new Error("injected lock close failure");
          },
        };
      },
      async unlink(target) {
        state.unlinked = true;
        return unlink(target);
      },
    },
  };
}

test("publishProof is idempotent across completed retries", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-publish-"));
  const remote = adapter();
  const proof = await packet();
  const input = {
    adapter: remote,
    journalRoot,
    runRoot: proof.runRoot,
    issueId: "MT-893",
    runId: "run-001",
    expectedCommit: "a".repeat(40),
    acceptanceCriteriaSha256: "c".repeat(64),
    workflowSha256: "d".repeat(64),
    reviewStateId: "state-uuid",
    manifest: proof.manifest,
  };

  const first = await publishProof(input);
  const second = await publishProof(input);

  assert.equal(first.status, "published");
  assert.equal(second.status, "published");
  assert.equal(remote.state.uploads, 1);
  assert.equal(remote.state.comments.length, 1);
  assert.equal(remote.state.transitions, 1);
});

test("publishProof reconciles a comment whose response was lost", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-publish-"));
  const remote = adapter();
  remote.state.throwAfterComment = true;
  const proof = await packet();
  const input = {
    adapter: remote,
    journalRoot,
    runRoot: proof.runRoot,
    issueId: "MT-893",
    runId: "run-001",
    expectedCommit: "a".repeat(40),
    acceptanceCriteriaSha256: "c".repeat(64),
    workflowSha256: "d".repeat(64),
    reviewStateId: "state-uuid",
    manifest: proof.manifest,
  };

  await assert.rejects(() => publishProof(input), /commit outcome unknown/i);
  remote.state.throwAfterComment = false;
  const recovered = await publishProof(input);

  assert.equal(recovered.status, "published");
  assert.equal(remote.state.uploads, 1);
  assert.equal(remote.state.comments.length, 1);
  assert.equal(remote.state.transitions, 1);
});

test("publishProof excludes concurrent publishers for one operation", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-publish-"));
  const remote = adapter();
  remote.state.uploadDelayMs = 50;
  const proof = await packet();
  const input = {
    adapter: remote,
    journalRoot,
    runRoot: proof.runRoot,
    issueId: "MT-893",
    runId: "run-001",
    expectedCommit: "a".repeat(40),
    acceptanceCriteriaSha256: "c".repeat(64),
    workflowSha256: "d".repeat(64),
    reviewStateId: "state-uuid",
    manifest: proof.manifest,
  };

  const outcomes = await Promise.allSettled([publishProof(input), publishProof(input)]);
  assert.equal(outcomes.filter((outcome) => outcome.status === "fulfilled").length, 1);
  assert.equal(outcomes.filter((outcome) => outcome.status === "rejected").length, 1);
  assert.match(outcomes.find((outcome) => outcome.status === "rejected").reason.message, /already active/i);
  assert.equal(remote.state.uploads, 1);
  assert.equal(remote.state.comments.length, 1);
  assert.equal(remote.state.transitions, 1);
});

test("publishProof removes locks when lock write or sync initialization fails", async () => {
  for (const phase of ["write", "sync"]) {
    const journalRoot = await mkdtemp(path.join(os.tmpdir(), `bethoven-lock-${phase}-`));
    const remote = adapter();
    const proof = await packet();
    const input = publicationInput(proof, journalRoot, remote);
    const injected = faultingLockFileSystem(phase);

    await assert.rejects(
      () => publishProof(input, { lockFileSystem: injected.fileSystem }),
      (error) => {
        assert.equal(error.publicCode, "publication_lock_failed");
        assert.match(error.publicMessage, /lock initialization failed/i);
        return true;
      },
    );
    assert.equal(injected.state.closed, true, phase);
    assert.equal(injected.state.unlinked, true, phase);
    assert.deepEqual((await readdir(journalRoot)).filter((entry) => entry.endsWith(".lock")), []);

    const recovered = await publishProof(input);
    assert.equal(recovered.status, "published");
  }
});

test("publishProof preserves journal write and file-close failures and remains retryable", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-journal-write-"));
  const remote = adapter();
  const proof = await packet();
  let injected = false;
  const fileSystem = {
    async open(target, flags, mode) {
      const handle = await open(target, flags, mode);
      const temporary = flags === "wx";
      return {
        async writeFile(...values) {
          if (temporary && !injected) {
            injected = true;
            throw new Error("injected journal write failure");
          }
          return handle.writeFile(...values);
        },
        sync: (...values) => handle.sync(...values),
        async close() {
          await handle.close();
          if (temporary && injected) throw new Error("injected journal file close failure");
        },
      };
    },
  };
  const input = publicationInput(proof, journalRoot, remote);

  await assert.rejects(
    () => publishProof(input, { journalFileSystem: fileSystem }),
    (error) => {
      assert.ok(error instanceof AggregateError);
      assert.match(error.errors[0].message, /journal write failure/i);
      assert.match(error.errors[1].message, /file close failure/i);
      return true;
    },
  );
  assert.deepEqual((await readdir(journalRoot)).filter((entry) => entry.endsWith(".tmp")), []);
  assert.equal(remote.state.uploads, 0);

  const recovered = await publishProof(input);
  assert.equal(recovered.status, "published");
});

test("publishProof distinguishes directory-sync failure from a post-sync close warning", async () => {
  const failedRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-journal-directory-fail-"));
  const failedRemote = adapter();
  const failedProof = await packet();
  let directoryOpenCount = 0;
  const failingFileSystem = {
    async open(target, flags, mode) {
      const handle = await open(target, flags, mode);
      if (flags !== "r") return handle;
      directoryOpenCount += 1;
      const ordinal = directoryOpenCount;
      return {
        async sync() {
          if (ordinal === 3) throw new Error("injected journal directory sync failure");
          return handle.sync();
        },
        async close() {
          await handle.close();
          if (ordinal === 3) throw new Error("injected journal directory close failure");
        },
      };
    },
  };

  await assert.rejects(
    () =>
      publishProof(publicationInput(failedProof, failedRoot, failedRemote), {
        journalFileSystem: failingFileSystem,
      }),
    (error) => {
      assert.equal(error.publicCode, "upload_outcome_unknown");
      assert.ok(error.cause instanceof AggregateError);
      assert.match(error.cause.errors[0].message, /directory sync failure/i);
      assert.match(error.cause.errors[1].message, /directory close failure/i);
      return true;
    },
  );
  assert.equal((await publicationJournal(failedRoot)).stage, "upload_unknown");
  assert.equal(failedRemote.state.uploads, 1);

  const warningRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-journal-directory-warning-"));
  const warningRemote = adapter();
  const warningProof = await packet();
  const warningFileSystem = {
    async open(target, flags, mode) {
      const handle = await open(target, flags, mode);
      if (flags !== "r") return handle;
      return {
        sync: (...values) => handle.sync(...values),
        async close() {
          await handle.close();
          throw new Error("injected post-sync directory close warning");
        },
      };
    },
  };

  const published = await publishProof(
    publicationInput(warningProof, warningRoot, warningRemote),
    { journalFileSystem: warningFileSystem },
  );
  assert.equal(published.status, "published");
  assert.deepEqual(published.cleanup_warnings, ["journal_directory_close_failed"]);
  assert.equal(warningRemote.state.uploads, 1);
  assert.equal(warningRemote.state.comments.length, 1);
  assert.equal(warningRemote.state.transitions, 1);
});

test("publishProof never publishes a failed packet", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-publish-"));
  const remote = adapter();
  const proof = await packet({ status: "failed" });

  await assert.rejects(
    () =>
      publishProof({
        adapter: remote,
        journalRoot,
        runRoot: proof.runRoot,
        issueId: "MT-893",
        runId: "run-001",
        expectedCommit: "a".repeat(40),
        acceptanceCriteriaSha256: "c".repeat(64),
        workflowSha256: "d".repeat(64),
        reviewStateId: "state-uuid",
        manifest: proof.manifest,
      }),
    /only passed/i,
  );
  assert.equal(remote.state.uploads, 0);
  assert.equal(remote.state.comments.length, 0);
  assert.equal(remote.state.transitions, 0);
});

test("publishProof binds publication to the manifest issue and a clean commit", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-publish-"));
  const remote = adapter();
  const proof = await packet();

  await assert.rejects(
    () =>
      publishProof({
        adapter: remote,
        journalRoot,
        runRoot: proof.runRoot,
        issueId: "MT-OTHER",
        runId: "run-001",
        expectedCommit: "a".repeat(40),
        acceptanceCriteriaSha256: "c".repeat(64),
        workflowSha256: "d".repeat(64),
        reviewStateId: "state-uuid",
        manifest: proof.manifest,
      }),
    /issue.*mismatch/i,
  );

  for (const override of [
    { runId: "run-other" },
    { expectedCommit: "e".repeat(40) },
    { acceptanceCriteriaSha256: "e".repeat(64) },
    { workflowSha256: "e".repeat(64) },
    { reviewStateId: "" },
    { reviewStateId: "x".repeat(257) },
  ]) {
    await assert.rejects(
      () =>
        publishProof({
          adapter: remote,
          journalRoot,
          runRoot: proof.runRoot,
          issueId: "MT-893",
          runId: "run-001",
          expectedCommit: "a".repeat(40),
          acceptanceCriteriaSha256: "c".repeat(64),
          workflowSha256: "d".repeat(64),
          reviewStateId: "state-uuid",
          manifest: proof.manifest,
          ...override,
        }),
      /identity mismatch/i,
    );
  }

  const dirtyProof = await packet({ dirty: true });
  await assert.rejects(
    () =>
      publishProof({
        adapter: remote,
        journalRoot,
        runRoot: dirtyProof.runRoot,
        issueId: "MT-893",
        runId: "run-001",
        expectedCommit: "a".repeat(40),
        acceptanceCriteriaSha256: "c".repeat(64),
        workflowSha256: "d".repeat(64),
        reviewStateId: "state-uuid",
        manifest: dirtyProof.manifest,
      }),
    /dirty/i,
  );

  assert.equal(remote.state.uploads, 0);
  assert.equal(remote.state.comments.length, 0);
  assert.equal(remote.state.transitions, 0);
});

test("publishProof fails closed on an ambiguous upload", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-publish-"));
  const remote = adapter();
  remote.state.throwAfterUpload = true;
  const proof = await packet();
  const input = {
    adapter: remote,
    journalRoot,
    runRoot: proof.runRoot,
    issueId: "MT-893",
    runId: "run-001",
    expectedCommit: "a".repeat(40),
    acceptanceCriteriaSha256: "c".repeat(64),
    workflowSha256: "d".repeat(64),
    reviewStateId: "state-uuid",
    manifest: proof.manifest,
  };

  await assert.rejects(
    () => publishProof(input),
    (error) => {
      assert.equal(error.publicCode, "upload_outcome_unknown");
      assert.match(error.publicMessage, /operator reconciliation/i);
      return true;
    },
  );
  remote.state.throwAfterUpload = false;
  await assert.rejects(() => publishProof(input), /operator reconciliation/i);
  assert.equal(remote.state.uploads, 1);
  assert.equal(remote.state.comments.length, 0);
  assert.equal(remote.state.transitions, 0);
});

test("publishProof keeps unsafe pre-PUT upload slots retryable", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-preflight-slot-"));
  const remote = adapter();
  const proof = await packet();
  const calls = { slots: 0, puts: 0 };
  let unsafe = true;
  const linear = new LinearProofAdapter({
    token: "test-token",
    fetch: async (_url, options) => {
      if (options.method === "POST") {
        calls.slots += 1;
        return new Response(
          JSON.stringify({
            data: {
              fileUpload: {
                success: true,
                uploadFile: {
                  uploadUrl: unsafe
                    ? "ftp://storage.example/signed-secret-canary"
                    : "https://storage.example/proof",
                  assetUrl: "https://uploads.linear.app/proof.webm",
                  headers: [{ key: "content-type", value: "video/webm" }],
                },
              },
            },
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }
      calls.puts += 1;
      return new Response(null, { status: 200 });
    },
  });
  remote.uploadArtifact = (artifact) => linear.uploadArtifact(artifact);
  const input = publicationInput(proof, journalRoot, remote);

  await assert.rejects(
    () => publishProof(input),
    (error) => {
      assert.equal(error.publicCode, "upload_preflight_failed");
      assert.doesNotMatch(error.publicMessage, /signed-secret-canary/);
      return true;
    },
  );
  assert.equal((await publicationJournal(journalRoot)).stage, "prepared");
  assert.deepEqual(calls, { slots: 1, puts: 0 });

  unsafe = false;
  const recovered = await publishProof(input);
  assert.equal(recovered.status, "published");
  assert.deepEqual(calls, { slots: 2, puts: 1 });
  assert.equal(remote.state.comments.length, 1);
  assert.equal(remote.state.transitions, 1);
});

test("publishProof keeps a pre-PUT video path replacement retryable", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-preflight-path-"));
  const remote = adapter();
  const proof = await packet();
  const videoPath = path.join(proof.runRoot, "receipt.webm");
  const video = await readFile(videoPath);
  let replacePath = true;
  let puts = 0;
  const linear = new LinearProofAdapter({
    token: "test-token",
    fileSystem: {
      async lstat(...args) {
        const metadata = await lstat(...args);
        if (replacePath) {
          replacePath = false;
          await rename(videoPath, `${videoPath}.original`);
          await writeFile(videoPath, video);
        }
        return metadata;
      },
    },
    fetch: async (_url, options) => {
      if (options.method === "POST") {
        return new Response(
          JSON.stringify({
            data: {
              fileUpload: {
                success: true,
                uploadFile: {
                  uploadUrl: "https://storage.example/proof",
                  assetUrl: "https://uploads.linear.app/proof.webm",
                  headers: [],
                },
              },
            },
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      }
      puts += 1;
      return new Response(null, { status: 200 });
    },
  });
  remote.uploadArtifact = (artifact) => linear.uploadArtifact(artifact);
  const input = publicationInput(proof, journalRoot, remote);

  await assert.rejects(
    () => publishProof(input),
    (error) => error.publicCode === "upload_preflight_failed",
  );
  assert.equal((await publicationJournal(journalRoot)).stage, "prepared");
  assert.equal(puts, 0);

  const recovered = await publishProof(input);
  assert.equal(recovered.status, "published");
  assert.equal(puts, 1);
});

test("publishProof renders asset URLs as one Markdown-safe image destination", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-markdown-"));
  const remote = adapter();
  remote.uploadArtifact = async () => ({
    assetUrl: "https://uploads.linear.app/a)![forged](https://evil.example/x",
  });
  const proof = await packet();

  const published = await publishProof(publicationInput(proof, journalRoot, remote));
  assert.equal(published.status, "published");
  const body = remote.state.comments[0].body;
  assert.equal(
    body.split("\n")[2],
    "![Visual proof for MT-893](<https://uploads.linear.app/a)![forged](https://evil.example/x>)",
  );
});

test("publishProof does not transition on an invalid reconciled comment ID", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-comment-id-"));
  const remote = adapter();
  const validFind = remote.findCommentByMarker;
  remote.findCommentByMarker = async (_issueId, _marker, expectedBody) => ({
    body: expectedBody,
  });
  const proof = await packet();
  const input = publicationInput(proof, journalRoot, remote);

  await assert.rejects(
    () => publishProof(input),
    (error) => error.publicCode === "linear_request_failed" && /invalid comment identity/i.test(error.message),
  );
  assert.equal((await publicationJournal(journalRoot)).stage, "uploaded");
  assert.equal(remote.state.uploads, 1);
  assert.equal(remote.state.comments.length, 0);
  assert.equal(remote.state.transitions, 0);

  remote.findCommentByMarker = validFind;
  const recovered = await publishProof(input);
  assert.equal(recovered.status, "published");
  assert.equal(remote.state.uploads, 1);
  assert.equal(remote.state.comments.length, 1);
  assert.equal(remote.state.transitions, 1);
});

test("publishProof requires exact mutation receipts before advancing", async () => {
  const commentRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-comment-receipt-"));
  const commentRemote = adapter();
  commentRemote.createComment = async (_issueId, body) => ({
    id: "comment-forged",
    body: `${body}\nforged suffix`,
  });
  const commentProof = await packet();

  await assert.rejects(
    () => publishProof(publicationInput(commentProof, commentRoot, commentRemote)),
    (error) => error.publicCode === "comment_outcome_unknown",
  );
  assert.equal((await publicationJournal(commentRoot)).stage, "comment_unknown");
  assert.equal(commentRemote.state.transitions, 0);

  const transitionRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-transition-receipt-"));
  const transitionRemote = adapter();
  transitionRemote.transitionIssue = async () => ({ success: true });
  transitionRemote.isIssueInState = async () => false;
  const transitionProof = await packet();

  await assert.rejects(
    () => publishProof(publicationInput(transitionProof, transitionRoot, transitionRemote)),
    (error) => error.publicCode === "transition_outcome_unknown",
  );
  assert.equal((await publicationJournal(transitionRoot)).stage, "transition_unknown");
  assert.equal(transitionRemote.state.comments.length, 1);
});

test("publishProof fails closed on a forged proof-marker collision", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-marker-collision-"));
  const remote = adapter();
  remote.findCommentByMarker = async (_issueId, marker, expectedBody) => {
    assert.match(expectedBody, new RegExp(marker));
    assert.match(expectedBody, /https:\/\/uploads\.linear\.app\/proof\.webm/);
    throw new LinearCommentCollisionError({ cause: new Error("secret collision details") });
  };
  const proof = await packet();

  await assert.rejects(() => publishProof(publicationInput(proof, journalRoot, remote)), (error) => {
    assert.equal(error.publicCode, "comment_marker_collision");
    assert.match(error.publicMessage, /marker collision.*operator review/i);
    assert.doesNotMatch(error.publicMessage, /secret collision details/i);
    return true;
  });
  assert.equal((await publicationJournal(journalRoot)).stage, "uploaded");
  assert.equal(remote.state.uploads, 1);
  assert.equal(remote.state.comments.length, 0);
  assert.equal(remote.state.transitions, 0);
});

test("publishProof does not let a close warning mask success or the primary failure", async () => {
  const successRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-lock-close-success-"));
  const successRemote = adapter();
  const successProof = await packet();
  const successLock = closeFailingLockFileSystem();
  const published = await publishProof(
    publicationInput(successProof, successRoot, successRemote),
    { lockFileSystem: successLock.fileSystem },
  );

  assert.equal(published.status, "published");
  assert.deepEqual(published.cleanup_warnings, ["lock_handle_close_failed"]);
  assert.equal(successLock.state.unlinked, true);
  assert.deepEqual((await readdir(successRoot)).filter((entry) => entry.endsWith(".lock")), []);

  const failureRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-lock-close-failure-"));
  const failureRemote = adapter();
  failureRemote.state.throwAfterUpload = true;
  const failureProof = await packet();
  const failureLock = closeFailingLockFileSystem();
  await assert.rejects(
    () =>
      publishProof(publicationInput(failureProof, failureRoot, failureRemote), {
        lockFileSystem: failureLock.fileSystem,
      }),
    (error) => {
      assert.equal(error.publicCode, "upload_outcome_unknown");
      assert.ok(error.cause instanceof AggregateError);
      assert.equal(error.cause.errors[0].publicCode, "upload_outcome_unknown");
      assert.match(error.cause.errors[1].message, /close failure/i);
      return true;
    },
  );
  assert.equal(failureLock.state.unlinked, true);
});

test("publishProof refuses to unlink a replacement lock", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-lock-replaced-"));
  const remote = adapter();
  const proof = await packet();
  const state = { lockPath: null, unlinkCalled: false };
  const fileSystem = {
    async open(target, ...args) {
      state.lockPath = target;
      const handle = await open(target, ...args);
      return {
        stat: (...values) => handle.stat(...values),
        writeFile: (...values) => handle.writeFile(...values),
        sync: (...values) => handle.sync(...values),
        async close() {
          await handle.close();
          await rename(target, `${target}.original`);
          await writeFile(target, "replacement publisher lock\n", { flag: "wx", mode: 0o600 });
        },
      };
    },
    async unlink(target) {
      state.unlinkCalled = true;
      return unlink(target);
    },
  };

  await assert.rejects(
    () => publishProof(publicationInput(proof, journalRoot, remote), { lockFileSystem: fileSystem }),
    (error) => {
      assert.equal(error.publicCode, "publication_lock_cleanup_required");
      assert.ok(error.cause instanceof AggregateError);
      assert.match(error.cause.errors[0].message, /identity changed/i);
      return true;
    },
  );
  assert.equal(state.unlinkCalled, false);
  assert.equal(await readFile(state.lockPath, "utf8"), "replacement publisher lock\n");
  assert.equal(remote.state.uploads, 1);
  assert.equal(remote.state.comments.length, 1);
  assert.equal(remote.state.transitions, 1);
  await unlink(state.lockPath);
  await unlink(`${state.lockPath}.original`);
});

test("publishProof aggregates a primary failure with an unlink failure", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-lock-unlink-"));
  const remote = adapter();
  remote.state.throwAfterUpload = true;
  const proof = await packet();
  let lockPath;
  const fileSystem = {
    async open(target, ...args) {
      lockPath = target;
      const handle = await open(target, ...args);
      return {
        stat: (...values) => handle.stat(...values),
        writeFile: (...values) => handle.writeFile(...values),
        sync: (...values) => handle.sync(...values),
        close: (...values) => handle.close(...values),
      };
    },
    async unlink() {
      const error = new Error("injected lock unlink failure");
      error.code = "EIO";
      throw error;
    },
  };

  await assert.rejects(
    () => publishProof(publicationInput(proof, journalRoot, remote), { lockFileSystem: fileSystem }),
    (error) => {
      assert.equal(error.publicCode, "publication_lock_cleanup_required");
      assert.ok(error.cause instanceof AggregateError);
      assert.equal(error.cause.errors[0].publicCode, "upload_outcome_unknown");
      assert.match(error.cause.errors[1].message, /unlink failure/i);
      return true;
    },
  );
  await unlink(lockPath);
});

test("publishProof reconciles a state transition whose response was lost", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-publish-"));
  const remote = adapter();
  remote.state.throwAfterTransition = true;
  const proof = await packet();
  const input = {
    adapter: remote,
    journalRoot,
    runRoot: proof.runRoot,
    issueId: "MT-893",
    runId: "run-001",
    expectedCommit: "a".repeat(40),
    acceptanceCriteriaSha256: "c".repeat(64),
    workflowSha256: "d".repeat(64),
    reviewStateId: "state-uuid",
    manifest: proof.manifest,
  };

  await assert.rejects(
    () => publishProof(input),
    (error) => {
      assert.equal(error.publicCode, "transition_outcome_unknown");
      assert.match(error.publicMessage, /retry to reconcile/i);
      return true;
    },
  );
  remote.state.throwAfterTransition = false;
  const recovered = await publishProof(input);
  assert.equal(recovered.status, "published");
  assert.equal(remote.state.uploads, 1);
  assert.equal(remote.state.comments.length, 1);
  assert.equal(remote.state.transitions, 1);
});

test("publishProof rejects a malformed durable journal", async () => {
  const journalRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-publish-"));
  const remote = adapter();
  const proof = await packet();
  const input = {
    adapter: remote,
    journalRoot,
    runRoot: proof.runRoot,
    issueId: "MT-893",
    runId: "run-001",
    expectedCommit: "a".repeat(40),
    acceptanceCriteriaSha256: "c".repeat(64),
    workflowSha256: "d".repeat(64),
    reviewStateId: "state-uuid",
    manifest: proof.manifest,
  };
  const first = await publishProof(input);
  const journalPath = path.join(journalRoot, `${first.journal.operation_key}.json`);
  await writeFile(journalPath, `${JSON.stringify({ ...first.journal, stage: "invented" })}\n`);

  await assert.rejects(() => publishProof(input), /publication journal/i);
  assert.equal(remote.state.uploads, 1);
  assert.equal(remote.state.comments.length, 1);
  assert.equal(remote.state.transitions, 1);
});
