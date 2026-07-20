import assert from "node:assert/strict";
import { mkdtemp, mkdir, symlink } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  redact,
  safeArtifactPath,
  safeSegment,
  validateTargetUrl,
} from "../src/security.mjs";

test("safeSegment accepts issue/run identifiers and rejects path material", () => {
  assert.equal(safeSegment("MT-893", "issue_id"), "MT-893");
  assert.equal(safeSegment("run_01-abc", "run_id"), "run_01-abc");

  for (const value of ["", "../secret", "nested/value", ".", "a".repeat(129)]) {
    assert.throws(() => safeSegment(value, "id"), /invalid id/i);
  }
});

test("validateTargetUrl defaults to an exact loopback origin", () => {
  const target = validateTargetUrl("http://127.0.0.1:4317/app");
  assert.equal(target.origin, "http://127.0.0.1:4317");

  assert.throws(() => validateTargetUrl("https://example.com"), /not allowed/i);
  assert.throws(() => validateTargetUrl("file:///etc/passwd"), /http/i);
  assert.throws(
    () => validateTargetUrl("http://user:pass@127.0.0.1:4317"),
    /credentials/i,
  );

  assert.equal(
    validateTargetUrl("https://preview.example.test", ["preview.example.test"]).hostname,
    "preview.example.test",
  );
});

test("safeArtifactPath rejects traversal and symlink escapes", async () => {
  const temp = await mkdtemp(path.join(os.tmpdir(), "bethoven-proof-security-"));
  const root = path.join(temp, "root");
  const rootAlias = path.join(temp, "root-alias");
  const outside = path.join(temp, "outside");
  await mkdir(root);
  await mkdir(outside);
  await symlink(root, rootAlias);
  await symlink(outside, path.join(root, "escape"));

  assert.equal(
    await safeArtifactPath(root, "video/proof.webm"),
    path.join(root, "video", "proof.webm"),
  );
  await assert.rejects(() => safeArtifactPath(root, "../outside/file"), /escapes/i);
  await assert.rejects(() => safeArtifactPath(root, "escape/file"), /symlink/i);
  await assert.rejects(() => safeArtifactPath(rootAlias, "video.webm"), /root.*symlink/i);
});

test("redact removes structured and inline credentials without retaining values", () => {
  const value = redact({
    api_key: "sk-secret",
    nested: {
      authorization: "Bearer abc",
      message: "request failed token=very-secret password=hunter2",
      safe: "kept",
    },
  });

  assert.equal(value.api_key, "[REDACTED]");
  assert.equal(value.nested.authorization, "[REDACTED]");
  assert.equal(value.nested.safe, "kept");
  assert.doesNotMatch(JSON.stringify(value), /sk-secret|very-secret|hunter2|Bearer abc/);
});
