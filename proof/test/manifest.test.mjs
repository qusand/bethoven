import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  canonicalJson,
  createProofManifest,
  sha256,
  verifyProofManifest,
} from "../src/manifest.mjs";

test("canonicalJson is stable across object insertion order", () => {
  assert.equal(
    canonicalJson({ z: 1, nested: { b: 2, a: 1 }, a: [3, 2, 1] }),
    canonicalJson({ a: [3, 2, 1], nested: { a: 1, b: 2 }, z: 1 }),
  );
});

test("proof manifest binds run, commit, assertions, and artifact digests", async () => {
  const runRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-proof-manifest-"));
  await mkdir(path.join(runRoot, "media"));
  await writeFile(path.join(runRoot, "media", "receipt.webm"), Buffer.from([0x1a, 0x45, 0xdf, 0xa3]));
  await writeFile(path.join(runRoot, "trace.zip"), Buffer.from("PK\u0003\u0004"));

  const manifest = await createProofManifest({
    runRoot,
    issueId: "MT-893",
    runId: "run-001",
    repository: {
      root: "/repo",
      head: "a".repeat(40),
      dirty: false,
      diff_sha256: null,
    },
    target: "http://127.0.0.1:4317",
    browser: { name: "chromium", version: "1" },
    viewport: { width: 1280, height: 720 },
    startedAt: "2026-07-20T12:00:00.000Z",
    finishedAt: "2026-07-20T12:00:03.000Z",
    status: "passed",
    proofPlanSha256: "b".repeat(64),
    acceptanceCriteriaSha256: "c".repeat(64),
    workflowSha256: "d".repeat(64),
    steps: [{ ordinal: 1, action: "expect_text", passed: true, duration_ms: 12 }],
    diagnostics: { console_errors: [], failed_requests: [] },
    artifacts: [
      { kind: "video", path: "media/receipt.webm", mediaType: "video/webm" },
      { kind: "trace", path: "trace.zip", mediaType: "application/zip" },
    ],
  });

  assert.equal(manifest.schema_version, 1);
  assert.equal(manifest.accounting.model_tokens, 0);
  assert.equal(manifest.bindings.proof_plan_sha256, "b".repeat(64));
  assert.equal(manifest.bindings.acceptance_criteria_sha256, "c".repeat(64));
  assert.equal(manifest.bindings.workflow_sha256, "d".repeat(64));
  assert.equal(manifest.artifacts.length, 2);
  assert.equal(manifest.artifacts[0].bytes, 4);
  assert.match(manifest.artifacts[0].sha256, /^[a-f0-9]{64}$/);
  assert.match(manifest.manifest_sha256, /^[a-f0-9]{64}$/);
  assert.deepEqual(await verifyProofManifest(runRoot, manifest), { valid: true });

  await writeFile(path.join(runRoot, "media", "receipt.webm"), "bad!");
  await assert.rejects(() => verifyProofManifest(runRoot, manifest), /digest mismatch/i);

  const invalidContainer = {
    ...manifest,
    artifacts: manifest.artifacts.map((artifact) =>
      artifact.kind === "video"
        ? { ...artifact, sha256: sha256(Buffer.from("bad!")) }
        : artifact,
    ),
  };
  delete invalidContainer.manifest_sha256;
  invalidContainer.manifest_sha256 = sha256(canonicalJson(invalidContainer));
  await assert.rejects(() => verifyProofManifest(runRoot, invalidContainer), /container signature/i);

  const serialized = await readFile(path.join(runRoot, "manifest.json"), "utf8");
  assert.equal(JSON.parse(serialized).manifest_sha256, manifest.manifest_sha256);
});

test("verification rejects a self-consistent passed manifest with failed or assertion-free steps", async () => {
  const runRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-proof-manifest-"));
  await writeFile(path.join(runRoot, "receipt.webm"), Buffer.from([0x1a, 0x45, 0xdf, 0xa3]));
  const base = await createProofManifest({
    runRoot,
    issueId: "MT-894",
    runId: "run-002",
    repository: {
      root: "/repo",
      head: "a".repeat(40),
      dirty: false,
      diff_sha256: null,
    },
    target: "http://127.0.0.1:4317",
    browser: { name: "chromium", version: "1" },
    viewport: { width: 1280, height: 720 },
    startedAt: "2026-07-20T12:00:00.000Z",
    finishedAt: "2026-07-20T12:00:03.000Z",
    status: "passed",
    proofPlanSha256: "b".repeat(64),
    acceptanceCriteriaSha256: "c".repeat(64),
    workflowSha256: "d".repeat(64),
    steps: [{ ordinal: 1, action: "expect_visible", passed: true, duration_ms: 12 }],
    diagnostics: { console_errors: [], failed_requests: [] },
    artifacts: [{ kind: "video", path: "receipt.webm", mediaType: "video/webm" }],
  });

  for (const steps of [
    [{ ordinal: 1, action: "expect_visible", passed: false, duration_ms: 12 }],
    [{ ordinal: 1, action: "goto", passed: true, duration_ms: 12 }],
    [
      { ordinal: 1, action: "expect_visible", passed: true, duration_ms: 12 },
      { ordinal: 2, action: "click", passed: true, duration_ms: 12 },
    ],
  ]) {
    const invalid = { ...base, steps };
    delete invalid.manifest_sha256;
    invalid.manifest_sha256 = sha256(canonicalJson(invalid));
    await assert.rejects(() => verifyProofManifest(runRoot, invalid), /passed proof|assertion/i);
  }
});
