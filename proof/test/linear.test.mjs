import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { lstat, mkdtemp, open, rename, writeFile } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  LinearMutationOutcomeError,
  LinearProofAdapter,
  LinearUploadError,
} from "../src/linear.mjs";

function proofArtifact(videoPath, video) {
  return {
    absolutePath: videoPath,
    media_type: "video/webm",
    bytes: video.length,
    sha256: createHash("sha256").update(video).digest("hex"),
  };
}

function slotFetch(uploadFile, calls) {
  return async (_url, options) => {
    if (options.method === "POST") {
      calls.slotRequests += 1;
      return new Response(
        JSON.stringify({ data: { fileUpload: { success: true, uploadFile } } }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }
    calls.putRequests += 1;
    return new Response(null, { status: 200 });
  };
}

async function linearServer() {
  const state = { uploads: [], comments: [], issueState: "todo-state" };
  const server = http.createServer(async (request, response) => {
    if (request.url === "/upload" && request.method === "PUT") {
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      state.uploads.push({
        body: Buffer.concat(chunks),
        cacheControl: request.headers["cache-control"],
        contentType: request.headers["content-type"],
        signed: request.headers["x-test-signature"],
      });
      response.writeHead(200).end();
      return;
    }

    if (request.url !== "/graphql" || request.method !== "POST") {
      response.writeHead(404).end();
      return;
    }

    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    assert.equal(request.headers.authorization, "test-token");

    let data;
    if (payload.query.includes("FileUpload")) {
      data = {
        fileUpload: {
          success: true,
          uploadFile: {
            uploadUrl: `http://127.0.0.1:${server.address().port}/upload`,
            assetUrl: "https://uploads.linear.app/test/receipt.webm",
            headers: [
              { key: "content-type", value: "video/webm" },
              { key: "x-test-signature", value: "signed" },
            ],
          },
        },
      };
    } else if (payload.query.includes("FindProofComment")) {
      const start = Number(payload.variables.after ?? 0);
      const end = Math.min(start + 50, state.comments.length);
      data = {
        issue: {
          comments: {
            nodes: state.comments.slice(start, end),
            pageInfo: {
              hasNextPage: end < state.comments.length,
              endCursor: end < state.comments.length ? String(end) : null,
            },
          },
        },
      };
    } else if (payload.query.includes("CreateProofComment")) {
      const comment = { id: `comment-${state.comments.length + 1}`, body: payload.variables.body };
      state.comments.push(comment);
      data = { commentCreate: { success: true, comment } };
    } else if (payload.query.includes("ProofIssueState")) {
      data = { issue: { state: { id: state.issueState } } };
    } else if (payload.query.includes("MoveProofIssue")) {
      state.issueState = payload.variables.stateId;
      data = {
        issueUpdate: {
          success: true,
          issue: {
            id: payload.variables.issueId,
            identifier: payload.variables.issueId,
            state: { id: state.issueState },
          },
        },
      };
    } else {
      throw new Error("unexpected GraphQL operation");
    }

    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify({ data }));
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return {
    state,
    endpoint: `http://127.0.0.1:${server.address().port}/graphql`,
    close: () => new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve()))),
  };
}

test("LinearProofAdapter performs the bounded upload/comment/state workflow", async (t) => {
  const remote = await linearServer();
  t.after(remote.close);
  const temp = await mkdtemp(path.join(os.tmpdir(), "bethoven-linear-"));
  const videoPath = path.join(temp, "receipt.webm");
  const video = Buffer.from([0x1a, 0x45, 0xdf, 0xa3]);
  await writeFile(videoPath, video);
  const adapter = new LinearProofAdapter({
    token: "test-token",
    endpoint: remote.endpoint,
    allowInsecureTestEndpoint: true,
  });

  const uploaded = await adapter.uploadArtifact(proofArtifact(videoPath, video));
  assert.equal(uploaded.assetUrl, "https://uploads.linear.app/test/receipt.webm");
  assert.equal(remote.state.uploads.length, 1);
  assert.deepEqual(remote.state.uploads[0].body, video);
  assert.equal(remote.state.uploads[0].cacheControl, undefined);
  assert.equal(remote.state.uploads[0].contentType, "video/webm");
  assert.equal(remote.state.uploads[0].signed, "signed");

  await assert.rejects(
    () =>
      adapter.uploadArtifact({
        absolutePath: videoPath,
        media_type: "video/webm",
        bytes: 4,
        sha256: "a".repeat(64),
      }),
    /digest/i,
  );
  assert.equal(remote.state.uploads.length, 1);

  assert.equal(
    await adapter.findCommentByMarker("issue-uuid", "proof-marker", "proof-marker\npacket"),
    null,
  );
  const comment = await adapter.createComment("issue-uuid", "proof-marker\npacket");
  assert.equal(comment.id, "comment-1");
  assert.equal(
    (await adapter.findCommentByMarker("issue-uuid", "proof-marker", "proof-marker\npacket")).id,
    "comment-1",
  );

  assert.equal(await adapter.isIssueInState("issue-uuid", "review-state"), false);
  await adapter.transitionIssue("issue-uuid", "review-state");
  assert.equal(await adapter.isIssueInState("issue-uuid", "review-state"), true);
});

test("LinearProofAdapter rejects non-Linear production endpoints", async () => {
  assert.throws(
    () => new LinearProofAdapter({ token: "token", endpoint: "https://example.com/graphql" }),
    /Linear API endpoint/i,
  );
});

test("LinearProofAdapter rejects malformed comment IDs and proof-marker collisions", async () => {
  for (const invalidId of [undefined, "x".repeat(257)]) {
    const adapter = new LinearProofAdapter({
      token: "test-token",
      fetch: async (_url, options) => {
        const payload = JSON.parse(options.body);
        const data = payload.query.includes("FindProofComment")
          ? {
              issue: {
                comments: {
                  nodes: [{ id: invalidId, body: "proof-marker\npacket" }],
                  pageInfo: { hasNextPage: false, endCursor: null },
                },
              },
            }
          : {
              commentCreate: {
                success: true,
                comment: { id: invalidId, body: "proof-marker\npacket" },
              },
            };
        return new Response(JSON.stringify({ data }), { status: 200 });
      },
    });

    await assert.rejects(
      () => adapter.findCommentByMarker("issue-uuid", "proof-marker", "proof-marker\npacket"),
      /invalid comment id/i,
    );
    await assert.rejects(
      () => adapter.createComment("issue-uuid", "proof-marker\npacket"),
      (error) => {
        assert.ok(error instanceof LinearMutationOutcomeError);
        assert.equal(error.operation, "comment");
        assert.equal(error.commitUnknown, true);
        assert.match(error.cause.message, /invalid comment id/i);
        return true;
      },
    );
  }

  const collisionAdapter = new LinearProofAdapter({
    token: "test-token",
    fetch: async () =>
      new Response(
        JSON.stringify({
          data: {
            issue: {
              comments: {
                nodes: [{ id: "forged-comment", body: "forged proof-marker" }],
                pageInfo: { hasNextPage: false, endCursor: null },
              },
            },
          },
        }),
        { status: 200 },
      ),
  });

  await assert.rejects(
    () =>
      collisionAdapter.findCommentByMarker(
        "issue-uuid",
        "proof-marker",
        "proof-marker\npacket",
      ),
    /marker collision/i,
  );
});

test("LinearProofAdapter treats malformed successful mutation responses as unknown", async () => {
  const wrongComment = new LinearProofAdapter({
    token: "test-token",
    fetch: async () =>
      new Response(
        JSON.stringify({
          data: {
            commentCreate: {
              success: true,
              comment: { id: "comment-ok", body: "forged body" },
            },
          },
        }),
        { status: 200 },
      ),
  });
  await assert.rejects(
    () => wrongComment.createComment("issue-uuid", "expected body"),
    (error) => {
      assert.ok(error instanceof LinearMutationOutcomeError);
      assert.equal(error.operation, "comment");
      assert.match(error.cause.message, /wrong proof-comment body/i);
      return true;
    },
  );

  for (const issue of [
    { id: "wrong-issue", identifier: "also-wrong", state: { id: "state-uuid" } },
    { id: "issue-uuid", identifier: "issue-uuid", state: { id: "wrong-state" } },
  ]) {
    const wrongTransition = new LinearProofAdapter({
      token: "test-token",
      fetch: async () =>
        new Response(
          JSON.stringify({ data: { issueUpdate: { success: true, issue } } }),
          { status: 200 },
        ),
    });
    await assert.rejects(
      () => wrongTransition.transitionIssue("issue-uuid", "state-uuid"),
      (error) => {
        assert.ok(error instanceof LinearMutationOutcomeError);
        assert.equal(error.operation, "transition");
        assert.equal(error.commitUnknown, true);
        assert.match(error.cause.message, /wrong transitioned issue state/i);
        return true;
      },
    );
  }

  const identifierTransition = new LinearProofAdapter({
    token: "test-token",
    fetch: async () =>
      new Response(
        JSON.stringify({
          data: {
            issueUpdate: {
              success: true,
              issue: {
                id: "00000000-0000-0000-0000-000000000001",
                identifier: "MT-893",
                state: { id: "state-uuid" },
              },
            },
          },
        }),
        { status: 200 },
      ),
  });
  assert.equal(
    (await identifierTransition.transitionIssue("MT-893", "state-uuid")).issueIdentifier,
    "MT-893",
  );
});

test("LinearProofAdapter rejects unsafe upload slots before issuing a PUT", async () => {
  const temp = await mkdtemp(path.join(os.tmpdir(), "bethoven-linear-slot-"));
  const videoPath = path.join(temp, "receipt.webm");
  const video = Buffer.from([0x1a, 0x45, 0xdf, 0xa3]);
  await writeFile(videoPath, video);
  const artifact = proofArtifact(videoPath, video);
  const valid = {
    uploadUrl: "https://storage.example/upload",
    assetUrl: "https://uploads.linear.app/test/receipt.webm",
    headers: [{ key: "content-type", value: "video/webm" }],
  };
  const cases = [
    {
      name: "malformed upload URL",
      uploadFile: { ...valid, uploadUrl: "not a URL signed-secret-canary" },
      pattern: /unsafe upload URL/i,
    },
    {
      name: "non-HTTPS upload URL",
      uploadFile: { ...valid, uploadUrl: "ftp://storage.example/signed-secret-canary" },
      pattern: /unsafe upload URL/i,
    },
    {
      name: "credentialed upload URL",
      uploadFile: { ...valid, uploadUrl: "https://user:signed-secret-canary@storage.example/upload" },
      pattern: /unsafe upload URL/i,
    },
    {
      name: "lookalike asset host",
      uploadFile: { ...valid, assetUrl: "https://uploads.linear.app.evil/receipt.webm" },
      pattern: /invalid asset URL/i,
    },
    {
      name: "credentialed asset URL",
      uploadFile: { ...valid, assetUrl: "https://user:signed-secret-canary@uploads.linear.app/receipt.webm" },
      pattern: /invalid asset URL/i,
    },
    {
      name: "non-default asset port",
      uploadFile: { ...valid, assetUrl: "https://uploads.linear.app:8443/receipt.webm" },
      pattern: /invalid asset URL/i,
    },
    {
      name: "duplicate signed header",
      uploadFile: {
        ...valid,
        headers: [
          { key: "content-type", value: "video/webm" },
          { key: "Content-Type", value: "video/webm" },
        ],
      },
      pattern: /duplicate upload headers/i,
    },
    {
      name: "CRLF header key",
      uploadFile: { ...valid, headers: [{ key: "x-signed\r\nheader", value: "value" }] },
      pattern: /invalid upload headers/i,
    },
    {
      name: "CRLF header value",
      uploadFile: { ...valid, headers: [{ key: "x-signed", value: "value\r\ninjected" }] },
      pattern: /invalid upload headers/i,
    },
  ];

  for (const scenario of cases) {
    const calls = { slotRequests: 0, putRequests: 0 };
    const adapter = new LinearProofAdapter({
      token: "test-token",
      fetch: slotFetch(scenario.uploadFile, calls),
    });
    await assert.rejects(
      () => adapter.uploadArtifact(artifact),
      (error) => {
        assert.ok(error instanceof LinearUploadError, scenario.name);
        assert.equal(error.phase, "preflight", scenario.name);
        assert.equal(error.putAttempted, false, scenario.name);
        assert.match(error.message, scenario.pattern, scenario.name);
        assert.doesNotMatch(error.message, /signed-secret-canary/, scenario.name);
        return true;
      },
    );
    assert.equal(calls.slotRequests, 1, scenario.name);
    assert.equal(calls.putRequests, 0, scenario.name);
  }
});

test("LinearProofAdapter rejects a path replacement between lstat and open", async () => {
  const temp = await mkdtemp(path.join(os.tmpdir(), "bethoven-linear-race-"));
  const videoPath = path.join(temp, "receipt.webm");
  const video = Buffer.from([0x1a, 0x45, 0xdf, 0xa3]);
  await writeFile(videoPath, video);
  let closeCount = 0;
  let requests = 0;

  const adapter = new LinearProofAdapter({
    token: "test-token",
    fetch: async () => {
      requests += 1;
      throw new Error("fetch must not run after an identity mismatch");
    },
    fileSystem: {
      async lstat(...args) {
        const metadata = await lstat(...args);
        await rename(videoPath, `${videoPath}.original`);
        await writeFile(videoPath, video);
        return metadata;
      },
      async open(...args) {
        const handle = await open(...args);
        return {
          stat: (...values) => handle.stat(...values),
          readFile: (...values) => handle.readFile(...values),
          async close() {
            closeCount += 1;
            return handle.close();
          },
        };
      },
    },
  });

  await assert.rejects(
    () => adapter.uploadArtifact(proofArtifact(videoPath, video)),
    (error) => {
      assert.ok(error instanceof LinearUploadError);
      assert.equal(error.phase, "preflight");
      assert.match(error.message, /changed before upload/i);
      return true;
    },
  );
  assert.equal(requests, 0);
  assert.equal(closeCount, 1);
});

test("LinearProofAdapter preserves video validation and handle-close failures", async () => {
  const temp = await mkdtemp(path.join(os.tmpdir(), "bethoven-linear-close-"));
  const videoPath = path.join(temp, "receipt.webm");
  const video = Buffer.from([0x1a, 0x45, 0xdf, 0xa3]);
  await writeFile(videoPath, video);

  const adapter = new LinearProofAdapter({
    token: "test-token",
    fetch: async () => {
      throw new Error("fetch must not run after an identity mismatch");
    },
    fileSystem: {
      async lstat(...args) {
        const metadata = await lstat(...args);
        await rename(videoPath, `${videoPath}.original`);
        await writeFile(videoPath, video);
        return metadata;
      },
      async open(...args) {
        const handle = await open(...args);
        return {
          stat: (...values) => handle.stat(...values),
          readFile: (...values) => handle.readFile(...values),
          async close() {
            await handle.close();
            throw new Error("injected handle close failure");
          },
        };
      },
    },
  });

  await assert.rejects(
    () => adapter.uploadArtifact(proofArtifact(videoPath, video)),
    (error) => {
      assert.ok(error instanceof LinearUploadError);
      assert.equal(error.phase, "preflight");
      assert.ok(error.cause instanceof AggregateError);
      assert.match(error.cause.errors[0].message, /changed before upload/i);
      assert.match(error.cause.errors[1].message, /close failure/i);
      return true;
    },
  );
});

test("LinearProofAdapter reconciles a proof marker beyond the first comment page", async (t) => {
  const remote = await linearServer();
  t.after(remote.close);
  for (let index = 0; index < 55; index += 1) {
    remote.state.comments.push({ id: `noise-${index}`, body: `unrelated ${index}` });
  }
  remote.state.comments.push({ id: "proof-comment", body: "bethoven-proof:target" });
  const adapter = new LinearProofAdapter({
    token: "test-token",
    endpoint: remote.endpoint,
    allowInsecureTestEndpoint: true,
  });

  assert.equal(
    (
      await adapter.findCommentByMarker(
        "issue-uuid",
        "bethoven-proof:target",
        "bethoven-proof:target",
      )
    ).id,
    "proof-comment",
  );
});
