import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { createProofManifest } from "../src/manifest.mjs";
import { publishProof } from "../src/publisher.mjs";

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
    async findCommentByMarker(_issueId, marker) {
      return state.comments.find((comment) => comment.body.includes(marker)) ?? null;
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

  await assert.rejects(() => publishProof(input), /upload response lost/i);
  remote.state.throwAfterUpload = false;
  await assert.rejects(() => publishProof(input), /operator reconciliation/i);
  assert.equal(remote.state.uploads, 1);
  assert.equal(remote.state.comments.length, 0);
  assert.equal(remote.state.transitions, 0);
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

  await assert.rejects(() => publishProof(input), /transition response lost/i);
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
