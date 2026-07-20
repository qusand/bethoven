import { createHash } from "node:crypto";
import { lstat, readFile } from "node:fs/promises";

const OFFICIAL_ENDPOINT = "https://api.linear.app/graphql";
const MAX_GRAPHQL_RESPONSE_BYTES = 1024 * 1024;
const MAX_VIDEO_BYTES = 50 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 15_000;
const MAX_COMMENT_PAGES = 10;

async function boundedBody(response, maximum = MAX_GRAPHQL_RESPONSE_BYTES) {
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maximum) throw new Error("Linear response exceeded the byte limit");
  if (!response.body) return "";

  const chunks = [];
  let total = 0;
  const reader = response.body.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maximum) {
      await reader.cancel();
      throw new Error("Linear response exceeded the byte limit");
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks.map((chunk) => Buffer.from(chunk))).toString("utf8");
}

function validTestEndpoint(endpoint) {
  try {
    const url = new URL(endpoint);
    return url.protocol === "http:" && ["127.0.0.1", "::1", "localhost"].includes(url.hostname);
  } catch {
    return false;
  }
}

function requiredString(value, name, maximum = 10_000) {
  if (typeof value !== "string" || value.length === 0 || value.length > maximum) {
    throw new Error(`invalid ${name}`);
  }
  return value;
}

export class LinearProofAdapter {
  constructor(options) {
    requiredString(options?.token, "Linear token", 4096);
    const endpoint = options.endpoint ?? OFFICIAL_ENDPOINT;
    if (
      endpoint !== OFFICIAL_ENDPOINT &&
      !(options.allowInsecureTestEndpoint === true && validTestEndpoint(endpoint))
    ) {
      throw new Error("invalid Linear API endpoint");
    }
    this.token = options.token;
    this.endpoint = endpoint;
    this.allowInsecureTestEndpoint = options.allowInsecureTestEndpoint === true;
    this.fetch = options.fetch ?? globalThis.fetch;
  }

  async request(query, variables) {
    const response = await this.fetch(this.endpoint, {
      method: "POST",
      redirect: "error",
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      headers: {
        authorization: this.token,
        "content-type": "application/json",
      },
      body: JSON.stringify({ query, variables }),
    });
    const text = await boundedBody(response);
    if (!response.ok) throw new Error(`Linear request failed with HTTP ${response.status}`);

    let payload;
    try {
      payload = JSON.parse(text);
    } catch {
      throw new Error("Linear returned invalid JSON");
    }
    if (Array.isArray(payload.errors) && payload.errors.length > 0) {
      throw new Error("Linear returned GraphQL errors");
    }
    if (!payload.data || typeof payload.data !== "object") {
      throw new Error("Linear response was missing data");
    }
    return payload.data;
  }

  async uploadArtifact(artifact) {
    if (artifact.media_type !== "video/webm") throw new Error("only WebM proof videos may be uploaded");
    if (!Number.isInteger(artifact.bytes) || artifact.bytes <= 0 || artifact.bytes > MAX_VIDEO_BYTES) {
      throw new Error("proof video is outside the upload byte limit");
    }
    if (!/^[a-f0-9]{64}$/.test(artifact.sha256 ?? "")) throw new Error("invalid proof video digest");

    const metadata = await lstat(artifact.absolutePath);
    if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size !== artifact.bytes) {
      throw new Error("proof video changed before upload");
    }
    const bytes = await readFile(artifact.absolutePath);
    if (createHash("sha256").update(bytes).digest("hex") !== artifact.sha256) {
      throw new Error("proof video digest changed before upload");
    }
    const filename = `bethoven-proof-${artifact.sha256}.webm`;
    const data = await this.request(
      `mutation FileUpload($filename: String!, $contentType: String!, $size: Int!) {
        fileUpload(filename: $filename, contentType: $contentType, size: $size) {
          success
          uploadFile { uploadUrl assetUrl headers { key value } }
        }
      }`,
      { filename, contentType: artifact.media_type, size: artifact.bytes },
    );
    const upload = data.fileUpload;
    if (!upload?.success || !upload.uploadFile) throw new Error("Linear did not create an upload slot");

    const uploadUrl = new URL(upload.uploadFile.uploadUrl);
    const assetUrl = new URL(upload.uploadFile.assetUrl);
    const uploadIsAllowed =
      uploadUrl.protocol === "https:" ||
      (this.allowInsecureTestEndpoint && validTestEndpoint(uploadUrl.href));
    if (!uploadIsAllowed) throw new Error("Linear returned an unsafe upload URL");
    if (assetUrl.protocol !== "https:" || assetUrl.hostname !== "uploads.linear.app") {
      throw new Error("Linear returned an invalid asset URL");
    }

    const headers = new Headers();
    const signedHeaders = upload.uploadFile.headers ?? [];
    if (!Array.isArray(signedHeaders) || signedHeaders.length > 32) {
      throw new Error("Linear returned invalid upload headers");
    }
    const seenHeaders = new Set();
    for (const header of signedHeaders) {
      const key = requiredString(header?.key, "upload header", 128);
      const value = requiredString(header?.value, "upload header value", 4096);
      if (/\r|\n/.test(key) || /\r|\n/.test(value)) throw new Error("Linear returned invalid upload headers");
      const normalizedKey = key.toLowerCase();
      if (seenHeaders.has(normalizedKey)) throw new Error("Linear returned duplicate upload headers");
      seenHeaders.add(normalizedKey);
      headers.set(key, value);
    }

    const response = await this.fetch(uploadUrl, {
      method: "PUT",
      redirect: "error",
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      headers,
      body: bytes,
    });
    if (!response.ok) throw new Error(`Linear upload failed with HTTP ${response.status}`);
    return { assetUrl: assetUrl.href };
  }

  async findCommentByMarker(issueId, marker) {
    requiredString(issueId, "issue id", 256);
    requiredString(marker, "proof marker", 256);
    let after = null;
    for (let page = 0; page < MAX_COMMENT_PAGES; page += 1) {
      const data = await this.request(
        `query FindProofComment($issueId: String!, $after: String) {
          issue(id: $issueId) {
            comments(first: 50, after: $after) {
              nodes { id body }
              pageInfo { hasNextPage endCursor }
            }
          }
        }`,
        { issueId, after },
      );
      const connection = data.issue?.comments;
      if (!Array.isArray(connection?.nodes) || !connection.pageInfo) {
        throw new Error("Linear comment query was incomplete");
      }
      const match = connection.nodes.find(
        (comment) => typeof comment.body === "string" && comment.body.includes(marker),
      );
      if (match) return match;
      if (connection.pageInfo.hasNextPage !== true) return null;
      after = requiredString(connection.pageInfo.endCursor, "comment cursor", 1024);
    }
    throw new Error("Linear comment reconciliation exceeded its page limit");
  }

  async createComment(issueId, body) {
    requiredString(issueId, "issue id", 256);
    requiredString(body, "proof comment", 10_000);
    const data = await this.request(
      `mutation CreateProofComment($issueId: String!, $body: String!) {
        commentCreate(input: { issueId: $issueId, body: $body }) {
          success
          comment { id body }
        }
      }`,
      { issueId, body },
    );
    if (!data.commentCreate?.success || !data.commentCreate.comment?.id) {
      throw new Error("Linear did not create the proof comment");
    }
    return data.commentCreate.comment;
  }

  async isIssueInState(issueId, stateId) {
    requiredString(issueId, "issue id", 256);
    requiredString(stateId, "state id", 256);
    const data = await this.request(
      `query ProofIssueState($issueId: String!) {
        issue(id: $issueId) { state { id } }
      }`,
      { issueId },
    );
    return data.issue?.state?.id === stateId;
  }

  async transitionIssue(issueId, stateId) {
    requiredString(issueId, "issue id", 256);
    requiredString(stateId, "state id", 256);
    const data = await this.request(
      `mutation MoveProofIssue($issueId: String!, $stateId: String!) {
        issueUpdate(id: $issueId, input: { stateId: $stateId }) {
          success
          issue { id }
        }
      }`,
      { issueId, stateId },
    );
    if (!data.issueUpdate?.success) throw new Error("Linear did not transition the issue");
    return data.issueUpdate;
  }
}
