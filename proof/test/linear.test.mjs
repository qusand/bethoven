import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { mkdtemp, writeFile } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { LinearProofAdapter } from "../src/linear.mjs";

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
      data = { issueUpdate: { success: true, issue: { id: payload.variables.issueId } } };
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

  const uploaded = await adapter.uploadArtifact({
    absolutePath: videoPath,
    media_type: "video/webm",
    bytes: 4,
    sha256: createHash("sha256").update(video).digest("hex"),
  });
  assert.equal(uploaded.assetUrl, "https://uploads.linear.app/test/receipt.webm");
  assert.equal(remote.state.uploads.length, 1);
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

  assert.equal(await adapter.findCommentByMarker("issue-uuid", "proof-marker"), null);
  const comment = await adapter.createComment("issue-uuid", "proof-marker\npacket");
  assert.equal(comment.id, "comment-1");
  assert.equal((await adapter.findCommentByMarker("issue-uuid", "proof-marker")).id, "comment-1");

  assert.equal(await adapter.isIssueInState("issue-uuid", "review-state"), false);
  await adapter.transitionIssue("issue-uuid", "review-state");
  assert.equal(await adapter.isIssueInState("issue-uuid", "review-state"), true);
});

test("LinearProofAdapter rejects non-Linear production endpoints and asset URLs", async () => {
  assert.throws(
    () => new LinearProofAdapter({ token: "token", endpoint: "https://example.com/graphql" }),
    /Linear API endpoint/i,
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

  assert.equal((await adapter.findCommentByMarker("issue-uuid", "bethoven-proof:target")).id, "proof-comment");
});
