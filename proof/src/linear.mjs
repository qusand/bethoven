import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { lstat, open } from "node:fs/promises";

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
    return (
      url.protocol === "http:" &&
      !url.username &&
      !url.password &&
      ["127.0.0.1", "::1", "localhost"].includes(url.hostname)
    );
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

function returnedUrl(value, errorMessage) {
  try {
    return new URL(requiredString(value, "Linear upload URL", 16_384));
  } catch {
    throw new Error(errorMessage);
  }
}

async function readUploadBytes(artifact, fileSystem) {
  const expectedSize = BigInt(artifact.bytes);
  const pathMetadata = await fileSystem.lstat(artifact.absolutePath, { bigint: true });
  if (
    !pathMetadata.isFile() ||
    pathMetadata.isSymbolicLink() ||
    pathMetadata.size !== expectedSize
  ) {
    throw new Error("proof video changed before upload");
  }

  const flags = constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0);
  let handle;
  try {
    handle = await fileSystem.open(artifact.absolutePath, flags);
  } catch (error) {
    throw new Error("proof video changed before upload", { cause: error });
  }

  let bytes;
  let primaryFailure = null;
  try {
    const openedMetadata = await handle.stat({ bigint: true });
    if (
      !openedMetadata.isFile() ||
      openedMetadata.size !== expectedSize ||
      openedMetadata.dev !== pathMetadata.dev ||
      openedMetadata.ino !== pathMetadata.ino
    ) {
      throw new Error("proof video changed before upload");
    }
    bytes = await handle.readFile();
    if (bytes.length !== artifact.bytes) throw new Error("proof video changed before upload");
    if (createHash("sha256").update(bytes).digest("hex") !== artifact.sha256) {
      throw new Error("proof video digest changed before upload");
    }
  } catch (error) {
    primaryFailure = error;
  }

  let closeFailure = null;
  try {
    await handle.close();
  } catch (error) {
    closeFailure = error;
  }

  if (primaryFailure && closeFailure) {
    throw new AggregateError(
      [primaryFailure, closeFailure],
      "proof video validation and handle cleanup failed",
    );
  }
  if (primaryFailure) throw primaryFailure;
  if (closeFailure) throw new Error("proof video handle cleanup failed", { cause: closeFailure });
  return bytes;
}

export class LinearUploadError extends Error {
  constructor(phase, message, options = {}) {
    super(message, options);
    this.name = "LinearUploadError";
    this.phase = phase;
    this.putAttempted = phase === "put";
  }
}

export class LinearCommentCollisionError extends Error {
  constructor(options = {}) {
    super("Linear proof marker collision requires operator review", options);
    this.name = "LinearCommentCollisionError";
  }
}

export class LinearMutationOutcomeError extends Error {
  constructor(operation, message, options = {}) {
    super(message, options);
    this.name = "LinearMutationOutcomeError";
    this.operation = operation;
    this.commitUnknown = true;
  }
}

function mutationOutcomeFailure(operation, message, error) {
  if (error instanceof LinearMutationOutcomeError) return error;
  return new LinearMutationOutcomeError(operation, message, { cause: error });
}

function uploadFailure(phase, error) {
  if (error instanceof LinearUploadError) return error;
  const message = error instanceof Error ? error.message : "Linear proof upload failed";
  return new LinearUploadError(phase, message, { cause: error });
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
    this.fileSystem = { lstat, open, ...(options.fileSystem ?? {}) };
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
    let bytes;
    let uploadUrl;
    let assetUrl;
    let headers;
    try {
      if (artifact.media_type !== "video/webm") throw new Error("only WebM proof videos may be uploaded");
      if (!Number.isInteger(artifact.bytes) || artifact.bytes <= 0 || artifact.bytes > MAX_VIDEO_BYTES) {
        throw new Error("proof video is outside the upload byte limit");
      }
      if (!/^[a-f0-9]{64}$/.test(artifact.sha256 ?? "")) throw new Error("invalid proof video digest");

      bytes = await readUploadBytes(artifact, this.fileSystem);
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

      uploadUrl = returnedUrl(upload.uploadFile.uploadUrl, "Linear returned an unsafe upload URL");
      assetUrl = returnedUrl(upload.uploadFile.assetUrl, "Linear returned an invalid asset URL");
      const uploadIsAllowed =
        (uploadUrl.protocol === "https:" && !uploadUrl.username && !uploadUrl.password) ||
        (this.allowInsecureTestEndpoint && validTestEndpoint(uploadUrl.href));
      if (!uploadIsAllowed) throw new Error("Linear returned an unsafe upload URL");
      if (
        assetUrl.protocol !== "https:" ||
        assetUrl.hostname !== "uploads.linear.app" ||
        assetUrl.port !== "" ||
        assetUrl.username ||
        assetUrl.password
      ) {
        throw new Error("Linear returned an invalid asset URL");
      }

      headers = new Headers();
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
    } catch (error) {
      throw uploadFailure("preflight", error);
    }

    try {
      const response = await this.fetch(uploadUrl, {
        method: "PUT",
        redirect: "error",
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        headers,
        body: bytes,
      });
      if (!response.ok) throw new Error(`Linear upload failed with HTTP ${response.status}`);
      return { assetUrl: assetUrl.href };
    } catch (error) {
      throw uploadFailure("put", error);
    }
  }

  async findCommentByMarker(issueId, marker, expectedBody) {
    requiredString(issueId, "issue id", 256);
    requiredString(marker, "proof marker", 256);
    requiredString(expectedBody, "expected proof comment", 10_000);
    if (!expectedBody.includes(marker)) throw new Error("expected proof comment is missing its marker");
    let after = null;
    let exactMatch = null;
    let collision = false;
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
      for (const comment of connection.nodes) {
        if (typeof comment.body !== "string" || !comment.body.includes(marker)) continue;
        if (comment.body !== expectedBody) {
          collision = true;
          continue;
        }
        const match = { ...comment, id: requiredString(comment.id, "comment id", 256) };
        if (exactMatch && exactMatch.id !== match.id) collision = true;
        exactMatch ??= match;
      }
      if (connection.pageInfo.hasNextPage !== true) {
        if (collision) throw new LinearCommentCollisionError();
        return exactMatch;
      }
      after = requiredString(connection.pageInfo.endCursor, "comment cursor", 1024);
    }
    throw new Error("Linear comment reconciliation exceeded its page limit");
  }

  async createComment(issueId, body) {
    requiredString(issueId, "issue id", 256);
    requiredString(body, "proof comment", 10_000);
    let data;
    try {
      data = await this.request(
        `mutation CreateProofComment($issueId: String!, $body: String!) {
          commentCreate(input: { issueId: $issueId, body: $body }) {
            success
            comment { id body }
          }
        }`,
        { issueId, body },
      );
    } catch (error) {
      throw mutationOutcomeFailure(
        "comment",
        "Linear proof-comment outcome is unknown",
        error,
      );
    }
    if (data.commentCreate?.success === false) {
      throw new Error("Linear did not create the proof comment");
    }
    try {
      const comment = data.commentCreate?.comment;
      if (data.commentCreate?.success !== true || !comment) {
        throw new Error("Linear returned an incomplete proof-comment result");
      }
      const id = requiredString(comment.id, "comment id", 256);
      if (comment.body !== body) throw new Error("Linear returned the wrong proof-comment body");
      return { ...comment, id };
    } catch (error) {
      throw mutationOutcomeFailure(
        "comment",
        "Linear proof-comment outcome is unknown",
        error,
      );
    }
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
    let data;
    try {
      data = await this.request(
        `mutation MoveProofIssue($issueId: String!, $stateId: String!) {
          issueUpdate(id: $issueId, input: { stateId: $stateId }) {
            success
            issue { id identifier state { id } }
          }
        }`,
        { issueId, stateId },
      );
    } catch (error) {
      throw mutationOutcomeFailure(
        "transition",
        "Linear review-state transition outcome is unknown",
        error,
      );
    }
    if (data.issueUpdate?.success === false) {
      throw new Error("Linear did not transition the issue");
    }
    try {
      const issue = data.issueUpdate?.issue;
      const returnedId = requiredString(issue?.id, "transitioned issue id", 256);
      const returnedIdentifier = requiredString(
        issue?.identifier,
        "transitioned issue identifier",
        256,
      );
      if (
        data.issueUpdate?.success !== true ||
        (returnedId !== issueId && returnedIdentifier !== issueId) ||
        requiredString(issue?.state?.id, "transitioned state id", 256) !== stateId
      ) {
        throw new Error("Linear returned the wrong transitioned issue state");
      }
      return {
        success: true,
        issueId: returnedId,
        issueIdentifier: returnedIdentifier,
        stateId: issue.state.id,
      };
    } catch (error) {
      throw mutationOutcomeFailure(
        "transition",
        "Linear review-state transition outcome is unknown",
        error,
      );
    }
  }
}
