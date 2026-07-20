import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, readFile, realpath, stat, writeFile } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

import { runProof } from "../src/runner.mjs";

async function cleanRepository() {
  const root = await mkdtemp(path.join(os.tmpdir(), "bethoven-proof-repo-"));
  const git = (...args) => {
    const result = spawnSync("git", ["-C", root, ...args], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };

  git("init", "--quiet");
  git("config", "user.name", "Bethoven Proof Test");
  git("config", "user.email", "proof@example.invalid");
  await writeFile(path.join(root, "README.md"), "fixture\n");
  git("add", "README.md");
  git("commit", "--quiet", "-m", "fixture");
  return { root, head: git("rev-parse", "HEAD") };
}

async function fixtureServer({ onRootRequest } = {}) {
  const server = http.createServer(async (request, response) => {
    if (request.url !== "/") {
      response.writeHead(404).end("not found");
      return;
    }

    await onRootRequest?.();
    response.setHeader("content-type", "text/html; charset=utf-8");
    response.end(`<!doctype html>
      <html><head><title>Proof fixture</title></head>
      <body>
        <main>
          <h1>Proof fixture</h1>
          <label>Todo <input id="todo" /></label>
          <button id="add">Add</button>
          <p id="result">Nothing added</p>
        </main>
        <script>
          console.error('opaque-canary-7392');
          const blocked = document.createElement('img');
          blocked.src = 'https://example.com/opaque-canary-7392?token=also-secret';
          document.body.appendChild(blocked);
          const socket = new WebSocket('wss://example.com/opaque-canary-7392?token=socket-secret');
          socket.onerror = () => {};
          document.querySelector('#add').addEventListener('click', () => {
            document.querySelector('#result').textContent = document.querySelector('#todo').value;
          });
        </script>
      </body></html>`);
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  return {
    origin: `http://127.0.0.1:${address.port}`,
    close: () => new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve()))),
  };
}

test("runProof creates assertion-backed video, trace, screenshot, and zero-token manifest", async (t) => {
  const repository = await cleanRepository();
  const stateRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-proof-state-"));
  const app = await fixtureServer();
  t.after(app.close);

  const result = await runProof({
    stateRoot,
    issueId: "MT-893",
    runId: "run-001",
    repositoryRoot: repository.root,
    expectedCommit: repository.head,
    acceptanceCriteriaSha256: "c".repeat(64),
    workflowSha256: "d".repeat(64),
    allowDirty: false,
    targetUrl: app.origin,
    viewport: { width: 1280, height: 720 },
    maxDurationMs: 20_000,
    steps: [
      { action: "goto", path: "/" },
      { action: "chapter", title: "Verify Todo entry", description: "Add one visible item" },
      { action: "expect_text", selector: "h1", text: "Proof fixture" },
      { action: "fill", selector: "#todo", value: "Milk" },
      { action: "click", selector: "#add" },
      { action: "expect_text", selector: "#result", text: "Milk" },
      { action: "screenshot", name: "result" },
    ],
  });

  assert.equal(result.manifest.status, "passed");
  assert.equal(result.manifest.accounting.model_tokens, 0);
  assert.match(result.manifest.bindings.proof_plan_sha256, /^[a-f0-9]{64}$/);
  assert.equal(result.manifest.bindings.acceptance_criteria_sha256, "c".repeat(64));
  assert.equal(result.manifest.bindings.workflow_sha256, "d".repeat(64));
  assert.ok(result.manifest.accounting.artifact_bytes > 0);
  assert.ok(result.manifest.accounting.assertion_count >= 2);
  assert.ok(result.manifest.steps.every((step) => step.passed));
  assert.doesNotMatch(JSON.stringify(result.manifest), /opaque-canary-7392|also-secret/);
  assert.ok(result.manifest.diagnostics.console_errors.length > 0);
  assert.ok(result.manifest.diagnostics.failed_requests.length > 0);
  assert.ok(
    result.manifest.diagnostics.failed_requests.some((entry) => entry.reason_code === "blocked_websocket"),
  );
  assert.deepEqual(result.manifest.repository, {
    root: await realpath(repository.root),
    head: repository.head,
    dirty: false,
    diff_sha256: null,
  });

  const byKind = Object.fromEntries(result.manifest.artifacts.map((artifact) => [artifact.kind, artifact]));
  for (const kind of ["video", "trace", "screenshot"]) {
    assert.ok(byKind[kind], `missing ${kind}`);
    assert.ok((await stat(path.join(result.runRoot, byKind[kind].path))).size > 0);
  }

  assert.deepEqual(
    [...(await readFile(path.join(result.runRoot, byKind.video.path))).subarray(0, 4)],
    [0x1a, 0x45, 0xdf, 0xa3],
  );
  assert.equal((await readFile(path.join(result.runRoot, byKind.trace.path))).subarray(0, 2).toString(), "PK");
  assert.deepEqual(
    [...(await readFile(path.join(result.runRoot, byKind.screenshot.path))).subarray(0, 8)],
    [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
  );
});

test("runProof rejects a stale or dirty checkout before launching a browser", async () => {
  const repository = await cleanRepository();
  const stateRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-proof-state-"));
  await writeFile(path.join(repository.root, "README.md"), "dirty\n");

  await assert.rejects(
    () =>
      runProof({
        stateRoot,
        issueId: "MT-894",
        runId: "run-002",
        repositoryRoot: repository.root,
        expectedCommit: repository.head,
        acceptanceCriteriaSha256: "c".repeat(64),
        workflowSha256: "d".repeat(64),
        allowDirty: false,
        targetUrl: "http://127.0.0.1:4317",
        steps: [{ action: "expect_visible", selector: "body" }],
      }),
    /working tree is dirty/i,
  );

  await assert.rejects(
    () =>
      runProof({
        stateRoot,
        issueId: "MT-894",
        runId: "run-003",
        repositoryRoot: repository.root,
        expectedCommit: "b".repeat(40),
        acceptanceCriteriaSha256: "c".repeat(64),
        workflowSha256: "d".repeat(64),
        allowDirty: true,
        targetUrl: "http://127.0.0.1:4317",
        steps: [{ action: "expect_visible", selector: "body" }],
      }),
    /commit mismatch/i,
  );
});

test("runProof rejects a checkout mutated during capture before creating a manifest", async (t) => {
  const repository = await cleanRepository();
  const stateRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-proof-state-"));
  const app = await fixtureServer({
    onRootRequest: () => writeFile(path.join(repository.root, "README.md"), "mutated during capture\n"),
  });
  t.after(app.close);

  await assert.rejects(
    () =>
      runProof({
        stateRoot,
        issueId: "MT-896",
        runId: "run-006",
        repositoryRoot: repository.root,
        expectedCommit: repository.head,
        acceptanceCriteriaSha256: "c".repeat(64),
        workflowSha256: "d".repeat(64),
        allowDirty: false,
        targetUrl: app.origin,
        viewport: { width: 1280, height: 720 },
        maxDurationMs: 20_000,
        steps: [
          { action: "goto", path: "/" },
          { action: "expect_text", selector: "h1", text: "Proof fixture" },
        ],
      }),
    /repository changed during proof capture/i,
  );

  const runRoot = path.join(stateRoot, "proof", "v1", "MT-896", "run-006");
  assert.ok((await stat(path.join(runRoot, "receipt.webm"))).size > 0);
  assert.ok((await stat(path.join(runRoot, "trace.zip"))).size > 0);
  await assert.rejects(() => readFile(path.join(runRoot, "manifest.json")), { code: "ENOENT" });
});

test("runProof rejects a passed proof plan with no deterministic assertion", async () => {
  const repository = await cleanRepository();
  const stateRoot = await mkdtemp(path.join(os.tmpdir(), "bethoven-proof-state-"));

  await assert.rejects(
    () =>
      runProof({
        stateRoot,
        issueId: "MT-895",
        runId: "run-004",
        repositoryRoot: repository.root,
        expectedCommit: repository.head,
        acceptanceCriteriaSha256: "c".repeat(64),
        workflowSha256: "d".repeat(64),
        allowDirty: false,
        targetUrl: "http://127.0.0.1:4317",
        steps: [{ action: "goto", path: "/" }],
      }),
    /assertion/i,
  );

  await assert.rejects(
    () =>
      runProof({
        stateRoot,
        issueId: "MT-895",
        runId: "run-005",
        repositoryRoot: repository.root,
        expectedCommit: repository.head,
        acceptanceCriteriaSha256: "c".repeat(64),
        workflowSha256: "d".repeat(64),
        allowDirty: false,
        targetUrl: "http://127.0.0.1:4317",
        steps: [
          { action: "expect_visible", selector: "body" },
          { action: "click", selector: "button" },
        ],
      }),
    /post-interaction assertion/i,
  );
});
