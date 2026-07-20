import { createHash } from "node:crypto";
import { chmod, lstat, open, readFile, stat } from "node:fs/promises";
import path from "node:path";

import { redact, safeArtifactPath, safeSegment } from "./security.mjs";

const SCHEMA_VERSION = 1;
const HEX_SHA256 = /^[a-f0-9]{64}$/;
const ACTIONS = new Set([
  "goto",
  "chapter",
  "fill",
  "click",
  "expect_text",
  "expect_visible",
  "screenshot",
  "wait",
]);
const ASSERTIONS = new Set(["expect_text", "expect_visible"]);
const INTERACTIONS = new Set(["goto", "fill", "click"]);
const ARTIFACT_MEDIA = new Map([
  ["video", "video/webm"],
  ["trace", "application/zip"],
  ["screenshot", "image/png"],
  ["failure_screenshot", "image/png"],
]);
const ARTIFACT_LIMITS = new Map([
  ["video", 50 * 1024 * 1024],
  ["trace", 200 * 1024 * 1024],
  ["screenshot", 20 * 1024 * 1024],
  ["failure_screenshot", 20 * 1024 * 1024],
]);

function canonicalValue(value) {
  if (value === null || typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("manifest contains a non-finite number");
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .filter((key) => value[key] !== undefined)
        .map((key) => [key, canonicalValue(value[key])]),
    );
  }
  throw new Error(`manifest contains unsupported value: ${typeof value}`);
}

export function canonicalJson(value) {
  return JSON.stringify(canonicalValue(value));
}

export function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

export function hasPostInteractionAssertion(steps) {
  let lastInteraction = -1;
  let lastAssertion = -1;
  for (const [index, step] of steps.entries()) {
    if (INTERACTIONS.has(step?.action)) lastInteraction = index;
    if (ASSERTIONS.has(step?.action)) lastAssertion = index;
  }
  return lastAssertion > lastInteraction;
}

function hasArtifactSignature(kind, bytes) {
  if (kind === "video") return bytes.subarray(0, 4).equals(Buffer.from([0x1a, 0x45, 0xdf, 0xa3]));
  if (kind === "trace") {
    const signature = bytes.subarray(0, 4);
    return [
      Buffer.from([0x50, 0x4b, 0x03, 0x04]),
      Buffer.from([0x50, 0x4b, 0x05, 0x06]),
      Buffer.from([0x50, 0x4b, 0x07, 0x08]),
    ].some((candidate) => signature.equals(candidate));
  }
  return bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
}

function verifyArtifactBytes(kind, bytes) {
  const maximum = ARTIFACT_LIMITS.get(kind);
  if (!maximum || bytes.length === 0 || bytes.length > maximum) {
    throw new Error(`artifact is outside its byte limit: ${kind}`);
  }
  if (!hasArtifactSignature(kind, bytes)) {
    throw new Error(`artifact has an invalid container signature: ${kind}`);
  }
}

async function artifactRecord(runRoot, artifact) {
  const absolutePath = await safeArtifactPath(runRoot, artifact.path);
  const metadata = await lstat(absolutePath);
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    throw new Error(`artifact is not a regular file: ${artifact.path}`);
  }
  if (metadata.size <= 0 || metadata.size > (ARTIFACT_LIMITS.get(artifact.kind) ?? 0)) {
    throw new Error(`artifact is outside its byte limit: ${artifact.kind}`);
  }
  const bytes = await readFile(absolutePath);
  if (bytes.length !== metadata.size) throw new Error(`artifact changed while reading: ${artifact.path}`);
  verifyArtifactBytes(artifact.kind, bytes);
  await chmod(absolutePath, 0o600);
  return {
    kind: safeSegment(artifact.kind, "artifact kind"),
    path: artifact.path.split(path.sep).join("/"),
    media_type: artifact.mediaType,
    bytes: metadata.size,
    sha256: sha256(bytes),
  };
}

function validateRepository(repository) {
  if (!repository || typeof repository !== "object") throw new Error("repository is required");
  if (typeof repository.root !== "string" || !path.isAbsolute(repository.root)) {
    throw new Error("repository root must be absolute");
  }
  if (typeof repository.head !== "string" || !/^[a-f0-9]{40,64}$/.test(repository.head)) {
    throw new Error("repository HEAD is invalid");
  }
  if (typeof repository.dirty !== "boolean") throw new Error("repository dirty flag is invalid");
  if (repository.dirty && !HEX_SHA256.test(repository.diff_sha256 ?? "")) {
    throw new Error("dirty repository diff digest is invalid");
  }
  if (!repository.dirty && repository.diff_sha256 !== null) {
    throw new Error("repository diff digest is invalid");
  }
  return repository;
}

function isoTimestamp(value, name) {
  if (
    typeof value !== "string" ||
    Number.isNaN(Date.parse(value)) ||
    new Date(value).toISOString() !== value
  ) {
    throw new Error(`${name} is not an ISO timestamp`);
  }
  return value;
}

function validateManifestSemantics(manifest) {
  safeSegment(manifest.issue_id, "issue_id");
  safeSegment(manifest.run_id, "run_id");
  if (manifest.status !== "passed" && manifest.status !== "failed") {
    throw new Error("proof status must be passed or failed");
  }
  validateRepository(manifest.repository);

  let target;
  try {
    target = new URL(manifest.target);
  } catch {
    throw new Error("manifest target is invalid");
  }
  if (!["http:", "https:"].includes(target.protocol) || target.username || target.password) {
    throw new Error("manifest target is invalid");
  }
  if (!manifest.browser || typeof manifest.browser !== "object") throw new Error("manifest browser is invalid");
  for (const field of ["name", "version"]) {
    if (typeof manifest.browser[field] !== "string" || manifest.browser[field].length === 0) {
      throw new Error("manifest browser is invalid");
    }
  }
  if (
    !manifest.viewport ||
    !Number.isInteger(manifest.viewport.width) ||
    !Number.isInteger(manifest.viewport.height) ||
    manifest.viewport.width < 320 ||
    manifest.viewport.width > 1920 ||
    manifest.viewport.height < 240 ||
    manifest.viewport.height > 1080
  ) {
    throw new Error("manifest viewport is invalid");
  }

  const startedAt = isoTimestamp(manifest.started_at, "started_at");
  const finishedAt = isoTimestamp(manifest.finished_at, "finished_at");
  const measuredDuration = Date.parse(finishedAt) - Date.parse(startedAt);
  if (
    measuredDuration < 0 ||
    !Number.isInteger(manifest.duration_ms) ||
    manifest.duration_ms !== measuredDuration ||
    measuredDuration > 90_000
  ) {
    throw new Error("manifest duration is invalid");
  }
  if (manifest.accounting?.model_tokens !== 0) throw new Error("manifest accounting is invalid");
  for (const field of [
    "artifact_bytes",
    "assertion_count",
    "capture_user_cpu_ms",
    "capture_system_cpu_ms",
    "capture_process_max_rss_bytes",
  ]) {
    if (!Number.isInteger(manifest.accounting?.[field]) || manifest.accounting[field] < 0) {
      throw new Error("manifest accounting is invalid");
    }
  }
  if (
    !manifest.bindings ||
    !HEX_SHA256.test(manifest.bindings.proof_plan_sha256 ?? "") ||
    !HEX_SHA256.test(manifest.bindings.acceptance_criteria_sha256 ?? "") ||
    !HEX_SHA256.test(manifest.bindings.workflow_sha256 ?? "")
  ) {
    throw new Error("manifest proof bindings are invalid");
  }

  if (!Array.isArray(manifest.steps) || manifest.steps.length === 0 || manifest.steps.length > 50) {
    throw new Error("manifest steps are invalid");
  }
  let hasAssertion = false;
  for (const [index, step] of manifest.steps.entries()) {
    if (
      !step ||
      typeof step !== "object" ||
      step.ordinal !== index + 1 ||
      !ACTIONS.has(step.action) ||
      typeof step.passed !== "boolean" ||
      !Number.isInteger(step.duration_ms) ||
      step.duration_ms < 0 ||
      step.duration_ms > 90_000
    ) {
      throw new Error("manifest step is invalid");
    }
    if (ASSERTIONS.has(step.action)) hasAssertion = true;
  }
  if (manifest.status === "passed" && manifest.steps.some((step) => !step.passed)) {
    throw new Error("passed proof contains a failed step");
  }
  if (manifest.status === "passed" && !hasAssertion) {
    throw new Error("passed proof has no deterministic assertion");
  }
  if (manifest.status === "passed" && !hasPostInteractionAssertion(manifest.steps)) {
    throw new Error("passed proof has no post-interaction assertion");
  }
  if (manifest.status === "failed" && manifest.steps.every((step) => step.passed)) {
    throw new Error("failed proof contains no failed step");
  }

  if (!Array.isArray(manifest.artifacts) || manifest.artifacts.length === 0 || manifest.artifacts.length > 64) {
    throw new Error("manifest artifacts are invalid");
  }
  const paths = new Set();
  let videos = 0;
  for (const artifact of manifest.artifacts) {
    if (
      !artifact ||
      typeof artifact !== "object" ||
      !ARTIFACT_MEDIA.has(artifact.kind) ||
      ARTIFACT_MEDIA.get(artifact.kind) !== artifact.media_type ||
      typeof artifact.path !== "string" ||
      artifact.path.length === 0 ||
      paths.has(artifact.path) ||
      !Number.isInteger(artifact.bytes) ||
      artifact.bytes <= 0 ||
      !HEX_SHA256.test(artifact.sha256 ?? "")
    ) {
      throw new Error("manifest artifact is invalid");
    }
    paths.add(artifact.path);
    if (artifact.kind === "video") videos += 1;
  }
  if (videos !== 1) throw new Error("manifest must contain exactly one proof video");
  if (manifest.accounting.artifact_bytes !== manifest.artifacts.reduce((sum, artifact) => sum + artifact.bytes, 0)) {
    throw new Error("manifest artifact accounting is invalid");
  }
  if (
    manifest.accounting.assertion_count !==
    manifest.steps.filter((step) => ASSERTIONS.has(step.action)).length
  ) {
    throw new Error("manifest assertion accounting is invalid");
  }
}

export async function createProofManifest(input) {
  safeSegment(input.issueId, "issue_id");
  safeSegment(input.runId, "run_id");
  if (input.status !== "passed" && input.status !== "failed") {
    throw new Error("proof status must be passed or failed");
  }

  const artifacts = [];
  for (const artifact of input.artifacts ?? []) {
    artifacts.push(await artifactRecord(input.runRoot, artifact));
  }

  const manifest = {
    schema_version: SCHEMA_VERSION,
    issue_id: input.issueId,
    run_id: input.runId,
    status: input.status,
    repository: validateRepository(input.repository),
    target: input.target,
    browser: redact(input.browser),
    viewport: input.viewport,
    started_at: isoTimestamp(input.startedAt, "started_at"),
    finished_at: isoTimestamp(input.finishedAt, "finished_at"),
    duration_ms: Math.max(0, Date.parse(input.finishedAt) - Date.parse(input.startedAt)),
    bindings: {
      proof_plan_sha256: input.proofPlanSha256,
      acceptance_criteria_sha256: input.acceptanceCriteriaSha256,
      workflow_sha256: input.workflowSha256,
    },
    accounting: {
      model_tokens: 0,
      artifact_bytes: artifacts.reduce((sum, artifact) => sum + artifact.bytes, 0),
      assertion_count: (input.steps ?? []).filter((step) => ASSERTIONS.has(step.action)).length,
      capture_user_cpu_ms: input.captureMetrics?.userCpuMs ?? 0,
      capture_system_cpu_ms: input.captureMetrics?.systemCpuMs ?? 0,
      capture_process_max_rss_bytes: input.captureMetrics?.processMaxRssBytes ?? 0,
    },
    steps: redact(input.steps ?? []),
    diagnostics: redact(input.diagnostics ?? {}),
    artifacts,
  };
  validateManifestSemantics(manifest);
  manifest.manifest_sha256 = sha256(canonicalJson(manifest));

  const manifestPath = await safeArtifactPath(input.runRoot, "manifest.json");
  const handle = await open(manifestPath, "wx", 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(manifest, null, 2)}\n`, "utf8");
    await handle.sync();
  } finally {
    await handle.close();
  }
  return manifest;
}

export async function verifyProofManifest(runRoot, manifest) {
  if (!manifest || manifest.schema_version !== SCHEMA_VERSION) {
    throw new Error("unsupported proof manifest schema");
  }
  if (!HEX_SHA256.test(manifest.manifest_sha256 ?? "")) {
    throw new Error("manifest digest is invalid");
  }

  const unsigned = { ...manifest };
  delete unsigned.manifest_sha256;
  if (sha256(canonicalJson(unsigned)) !== manifest.manifest_sha256) {
    throw new Error("manifest digest mismatch");
  }
  validateManifestSemantics(unsigned);

  for (const artifact of manifest.artifacts ?? []) {
    const absolutePath = await safeArtifactPath(runRoot, artifact.path);
    const metadata = await stat(absolutePath);
    if (metadata.size <= 0 || metadata.size > (ARTIFACT_LIMITS.get(artifact.kind) ?? 0)) {
      throw new Error(`artifact is outside its byte limit: ${artifact.path}`);
    }
    const bytes = await readFile(absolutePath);
    if (metadata.size !== artifact.bytes || bytes.length !== artifact.bytes) {
      throw new Error(`artifact size mismatch: ${artifact.path}`);
    }
    if (sha256(bytes) !== artifact.sha256) throw new Error(`artifact digest mismatch: ${artifact.path}`);
    verifyArtifactBytes(artifact.kind, bytes);
  }
  return { valid: true };
}
