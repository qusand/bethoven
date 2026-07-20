import { lstat, realpath } from "node:fs/promises";
import path from "node:path";

const SEGMENT_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const SENSITIVE_KEY = /(?:^|[_-])(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|passwd|authorization|cookie|session)(?:$|[_-])/i;
const INLINE_SECRET = /\b(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|passwd|authorization|cookie|session)\b\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)/gi;
const BEARER_SECRET = /\bBearer\s+[A-Za-z0-9._~+/=-]+/gi;

function isMissing(error) {
  return error && error.code === "ENOENT";
}

export function safeSegment(value, name = "segment") {
  if (
    typeof value !== "string" ||
    !SEGMENT_PATTERN.test(value) ||
    value === "." ||
    value === ".."
  ) {
    throw new Error(`invalid ${name}`);
  }
  return value;
}

export function validateTargetUrl(value, allowedHosts = []) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error("target must be a valid HTTP URL");
  }

  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("target must use HTTP or HTTPS");
  }
  if (url.username || url.password) {
    throw new Error("target URL credentials are forbidden");
  }

  const loopback = new Set(["127.0.0.1", "::1", "localhost"]);
  const operatorAllowed = new Set(
    allowedHosts.map((host) => {
      if (typeof host !== "string" || host.length === 0 || host.length > 253) {
        throw new Error("invalid allowed host");
      }
      return host.toLowerCase();
    }),
  );

  if (!loopback.has(url.hostname.toLowerCase()) && !operatorAllowed.has(url.hostname.toLowerCase())) {
    throw new Error(`target host is not allowed: ${url.hostname}`);
  }
  return url;
}

export async function safeArtifactPath(root, relativePath) {
  if (typeof relativePath !== "string" || relativePath.length === 0 || relativePath.length > 1024) {
    throw new Error("invalid artifact path");
  }
  if (relativePath.includes("\0") || path.isAbsolute(relativePath)) {
    throw new Error("artifact path escapes its run root");
  }

  const rootPath = path.resolve(root);
  const rootMetadata = await lstat(rootPath);
  if (!rootMetadata.isDirectory() || rootMetadata.isSymbolicLink()) {
    throw new Error("artifact root must be a real directory, not a symlink");
  }
  const canonicalRoot = await realpath(rootPath);
  const candidate = path.resolve(rootPath, relativePath);
  const relation = path.relative(rootPath, candidate);
  if (relation === ".." || relation.startsWith(`..${path.sep}`) || path.isAbsolute(relation)) {
    throw new Error("artifact path escapes its run root");
  }

  let current = rootPath;
  for (const segment of relation.split(path.sep).filter(Boolean)) {
    current = path.join(current, segment);
    try {
      const metadata = await lstat(current);
      if (metadata.isSymbolicLink()) {
        throw new Error("artifact path crosses a symlink");
      }
      const resolved = await realpath(current);
      const resolvedRelation = path.relative(canonicalRoot, resolved);
      if (
        resolvedRelation === ".." ||
        resolvedRelation.startsWith(`..${path.sep}`) ||
        path.isAbsolute(resolvedRelation)
      ) {
        throw new Error("artifact path escapes its run root");
      }
    } catch (error) {
      if (isMissing(error)) break;
      throw error;
    }
  }

  return candidate;
}

function redactString(value) {
  return value
    .slice(0, 4096)
    .replace(BEARER_SECRET, "Bearer [REDACTED]")
    .replace(INLINE_SECRET, (_match, key) => `${key}=[REDACTED]`);
}

export function redact(value, depth = 0) {
  if (depth > 8) return "[TRUNCATED]";
  if (typeof value === "string") return redactString(value);
  if (value === null || typeof value === "number" || typeof value === "boolean") return value;
  if (Array.isArray(value)) return value.slice(0, 100).map((item) => redact(item, depth + 1));
  if (typeof value !== "object") return String(value).slice(0, 256);

  const result = {};
  for (const [key, item] of Object.entries(value).slice(0, 100)) {
    result[key] = SENSITIVE_KEY.test(key) ? "[REDACTED]" : redact(item, depth + 1);
  }
  return result;
}
