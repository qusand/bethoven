import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const publisher = fileURLToPath(new URL("../bin/bethoven-publish-linear.mjs", import.meta.url));

function runPublisher(arguments_, environment = process.env) {
  return spawnSync(process.execPath, [publisher, ...arguments_], {
    encoding: "utf8",
    env: environment,
  });
}

test("publisher CLI reports bounded public argument errors without echoing input", () => {
  const result = runPublisher(["--signed-secret-canary", "token=signed-secret-canary"]);

  assert.equal(result.status, 1);
  assert.match(result.stderr, /failed \[invalid_arguments\]: unknown publication argument/);
  assert.doesNotMatch(result.stderr, /signed-secret-canary|token=/);
  assert.equal(result.stdout, "");
});

test("publisher CLI distinguishes a missing credential from publication failures", () => {
  const environment = { ...process.env };
  delete environment.LINEAR_API_KEY;
  const result = runPublisher(
    [
      "--run-root", "/nonexistent/run",
      "--journal-root", "/nonexistent/journal",
      "--issue-id", "MT-1",
      "--run-id", "run-1",
      "--expected-commit", "a".repeat(40),
      "--acceptance-criteria-sha256", "b".repeat(64),
      "--workflow-sha256", "c".repeat(64),
      "--review-state-id", "state-1",
      "--confirm-linear-write",
    ],
    environment,
  );

  assert.equal(result.status, 1);
  assert.match(result.stderr, /failed \[credentials_missing\]: LINEAR_API_KEY is required/);
  assert.doesNotMatch(result.stderr, /nonexistent|stack|file:/i);
  assert.equal(result.stdout, "");
});
