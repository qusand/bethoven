import assert from "node:assert/strict";
import { mkdtemp, mkdir, open, readFile, unlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  canonicalJson,
  createProofManifest,
  sha256,
  verifyProofManifest,
} from "../src/manifest.mjs";

function passingManifestInput(runRoot) {
  return {
    runRoot,
    issueId: "MT-FAULT",
    runId: "run-fault",
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
  };
}

function faultingManifestFileSystem(phase) {
  const state = {
    failed: false,
    fileClosed: false,
    directorySyncAttempts: 0,
  };
  return {
    state,
    fileSystem: {
      async open(target, flags, mode) {
        const handle = await open(target, flags, mode);
        const manifestFile = flags === "wx";
        return {
          async writeFile(...args) {
            if (manifestFile && phase === "write" && !state.failed) {
              state.failed = true;
              throw new Error("injected manifest write failure");
            }
            return handle.writeFile(...args);
          },
          async sync() {
            if (!manifestFile) state.directorySyncAttempts += 1;
            if (
              !state.failed &&
              ((manifestFile && phase === "file-sync") ||
                (!manifestFile && phase === "directory-sync"))
            ) {
              state.failed = true;
              throw new Error(`injected manifest ${phase} failure`);
            }
            return handle.sync();
          },
          async close() {
            if (manifestFile) state.fileClosed = true;
            return handle.close();
          },
        };
      },
      unlink,
    },
  };
}

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

  const input = {
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
  };
  const manifest = await createProofManifest(input);

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

  const serialized = await readFile(path.join(runRoot, "manifest.json"), "utf8");
  assert.equal(JSON.parse(serialized).manifest_sha256, manifest.manifest_sha256);
  await assert.rejects(
    () => createProofManifest(input),
    (error) => error.code === "EEXIST",
  );
  assert.equal(await readFile(path.join(runRoot, "manifest.json"), "utf8"), serialized);

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
});

test("manifest persistence rolls back write and sync failures so retries remain possible", async () => {
  for (const phase of ["write", "file-sync", "directory-sync"]) {
    const runRoot = await mkdtemp(path.join(os.tmpdir(), `bethoven-manifest-${phase}-`));
    await writeFile(path.join(runRoot, "receipt.webm"), Buffer.from([0x1a, 0x45, 0xdf, 0xa3]));
    const input = passingManifestInput(runRoot);
    const injected = faultingManifestFileSystem(phase);

    await assert.rejects(
      () => createProofManifest(input, { fileSystem: injected.fileSystem }),
      /injected manifest/i,
    );
    await assert.rejects(
      () => readFile(path.join(runRoot, "manifest.json")),
      (error) => error.code === "ENOENT",
    );
    assert.equal(injected.state.fileClosed, true, phase);
    assert.ok(injected.state.directorySyncAttempts >= 1, phase);

    const recovered = await createProofManifest(input);
    assert.deepEqual(await verifyProofManifest(runRoot, recovered), { valid: true });
  }
});

test("manifest persistence preserves paired primary and cleanup failures", async () => {
  const fileRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-manifest-file-pair-"));
  await writeFile(path.join(fileRoot, "receipt.webm"), Buffer.from([0x1a, 0x45, 0xdf, 0xa3]));
  let failFileClose = true;
  const filePair = {
    async open(target, flags, mode) {
      const handle = await open(target, flags, mode);
      if (flags !== "wx") return handle;
      return {
        async writeFile() {
          throw new Error("injected paired manifest write failure");
        },
        sync: (...args) => handle.sync(...args),
        async close() {
          await handle.close();
          if (failFileClose) {
            failFileClose = false;
            throw new Error("injected paired manifest file close failure");
          }
        },
      };
    },
    unlink,
  };
  await assert.rejects(
    () => createProofManifest(passingManifestInput(fileRoot), { fileSystem: filePair }),
    (error) => {
      assert.ok(error instanceof AggregateError);
      assert.match(error.errors[0].message, /write failure/i);
      assert.match(error.errors[1].message, /file close failure/i);
      return true;
    },
  );

  const rollbackRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-manifest-rollback-pair-"));
  await writeFile(path.join(rollbackRoot, "receipt.webm"), Buffer.from([0x1a, 0x45, 0xdf, 0xa3]));
  const rollbackPair = {
    async open(target, flags, mode) {
      const handle = await open(target, flags, mode);
      if (flags === "wx") {
        return {
          async writeFile() {
            throw new Error("injected rollback-triggering write failure");
          },
          sync: (...args) => handle.sync(...args),
          close: (...args) => handle.close(...args),
        };
      }
      return {
        async sync() {
          throw new Error("injected rollback directory sync failure");
        },
        async close() {
          await handle.close();
          throw new Error("injected rollback directory close failure");
        },
      };
    },
    async unlink() {
      throw new Error("injected rollback unlink failure");
    },
  };
  await assert.rejects(
    () => createProofManifest(passingManifestInput(rollbackRoot), { fileSystem: rollbackPair }),
    (error) => {
      assert.match(error.message, /cleanup failed.*operator intervention/i);
      assert.ok(error.cause instanceof AggregateError);
      assert.match(error.cause.errors[0].message, /write failure/i);
      assert.ok(error.cause.errors[1] instanceof AggregateError);
      assert.match(error.cause.errors[1].errors[0].message, /unlink failure/i);
      assert.ok(error.cause.errors[1].errors[1] instanceof AggregateError);
      assert.match(error.cause.errors[1].errors[1].errors[0].message, /directory sync failure/i);
      assert.match(error.cause.errors[1].errors[1].errors[1].message, /directory close failure/i);
      return true;
    },
  );

  await unlink(path.join(rollbackRoot, "manifest.json"));
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
