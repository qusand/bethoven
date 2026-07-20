import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import {
  chmod,
  lstat,
  mkdir,
  readFile,
  realpath,
  stat,
} from "node:fs/promises";
import path from "node:path";

import {
  canonicalJson,
  createProofManifest,
  hasPostInteractionAssertion,
  sha256,
} from "./manifest.mjs";
import {
  safeSegment,
  validateTargetUrl,
} from "./security.mjs";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const MAX_STEPS = 50;
const MAX_DURATION_MS = 90_000;
const DEFAULT_STEP_TIMEOUT_MS = 5_000;

function git(repositoryRoot, args) {
  const result = spawnSync("git", ["-C", repositoryRoot, ...args], {
    encoding: null,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`git command failed: ${args[0]}`);
  }
  return result.stdout;
}

async function repositoryFingerprint(repositoryRoot) {
  const root = await realpath(repositoryRoot);
  const head = git(root, ["rev-parse", "HEAD"]).toString("utf8").trim();
  const statusBytes = git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]);
  const dirty = statusBytes.length > 0;
  if (!dirty) return { root, head, dirty: false, diff_sha256: null };

  const digest = createHash("sha256");
  digest.update(statusBytes);
  digest.update(git(root, ["diff", "--binary", "--no-ext-diff", "HEAD", "--"]));

  const entries = statusBytes.toString("utf8").split("\0").filter(Boolean);
  for (const entry of entries) {
    if (!entry.startsWith("?? ")) continue;
    const relative = entry.slice(3);
    try {
      digest.update(relative);
      digest.update(await readFile(path.join(root, relative)));
    } catch {
      digest.update("[unreadable]");
    }
  }
  return { root, head, dirty: true, diff_sha256: digest.digest("hex") };
}

function sameRepositoryFingerprint(initial, final) {
  return (
    initial.root === final.root &&
    initial.head === final.head &&
    initial.dirty === final.dirty &&
    initial.diff_sha256 === final.diff_sha256
  );
}

function validateViewport(viewport = { width: 1280, height: 720 }) {
  if (
    !Number.isInteger(viewport.width) ||
    !Number.isInteger(viewport.height) ||
    viewport.width < 320 ||
    viewport.width > 1920 ||
    viewport.height < 240 ||
    viewport.height > 1080
  ) {
    throw new Error("viewport is outside the bounded range");
  }
  return viewport;
}

async function ensureDirectory(directory) {
  try {
    await mkdir(directory, { mode: 0o700 });
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
  }
  const metadata = await lstat(directory);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    throw new Error(`unsafe proof directory: ${directory}`);
  }
  await chmod(directory, 0o700);
}

async function prepareRunRoot(stateRoot, issueId, runId) {
  if (typeof stateRoot !== "string" || !path.isAbsolute(stateRoot)) {
    throw new Error("stateRoot must be an absolute path");
  }

  await mkdir(stateRoot, { recursive: true, mode: 0o700 });
  const rootMetadata = await lstat(stateRoot);
  if (!rootMetadata.isDirectory() || rootMetadata.isSymbolicLink()) {
    throw new Error("stateRoot must be a real directory");
  }
  await chmod(stateRoot, 0o700);

  let current = await realpath(stateRoot);
  for (const segment of ["proof", "v1", issueId]) {
    current = path.join(current, segment);
    await ensureDirectory(current);
  }

  const runRoot = path.join(current, runId);
  try {
    await mkdir(runRoot, { mode: 0o700 });
  } catch (error) {
    if (error.code === "EEXIST") throw new Error("proof run already exists");
    throw error;
  }
  return runRoot;
}

function boundedString(value, name, maximum) {
  if (typeof value !== "string" || value.length === 0 || value.length > maximum) {
    throw new Error(`invalid ${name}`);
  }
  return value;
}

function allowedRequest(url, target, allowedHosts) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  if (["about:", "blob:", "data:"].includes(parsed.protocol)) return true;
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
  if (parsed.origin === target.origin) return true;
  return allowedHosts.has(parsed.hostname.toLowerCase());
}

function allowedWebSocket(url, target, allowedHosts) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  if (parsed.protocol !== "ws:" && parsed.protocol !== "wss:") return false;
  const targetSocket = new URL(target.href);
  targetSocket.protocol = target.protocol === "https:" ? "wss:" : "ws:";
  if (parsed.origin === targetSocket.origin) return true;
  return allowedHosts.has(parsed.hostname.toLowerCase());
}

function selectorDigest(selector) {
  return sha256(selector).slice(0, 16);
}

function diagnosticFingerprint(kind, value) {
  const bytes = Buffer.from(String(value).slice(0, 65_536));
  return { kind, bytes: bytes.length, sha256: sha256(bytes) };
}

function requestFingerprint(url, reasonCode, reason = null) {
  let origin = "[invalid-origin]";
  try {
    origin = new URL(url).origin;
  } catch {
    // Keep the invalid sentinel without retaining untrusted URL text.
  }
  const record = {
    origin,
    url_sha256: sha256(String(url)),
    reason_code: reasonCode,
  };
  if (reason) record.reason_sha256 = sha256(String(reason));
  return record;
}

function stepRecord(step, ordinal, passed, durationMs, errorCode = null) {
  const record = {
    ordinal,
    action: step.action,
    passed,
    duration_ms: durationMs,
  };
  if (typeof step.selector === "string") record.selector_sha256 = selectorDigest(step.selector);
  if (errorCode) record.error_code = errorCode;
  return record;
}

async function executeStep({ page, target, step, ordinal, timeoutMs, screenshotDirectory, artifacts }) {
  if (!step || typeof step !== "object") throw new Error("invalid proof step");
  const action = boundedString(step.action, "step action", 64);

  switch (action) {
    case "goto": {
      const relative = boundedString(step.path, "navigation path", 1024);
      const destination = new URL(relative, target);
      if (destination.origin !== target.origin) throw new Error("navigation escaped the target origin");
      await page.goto(destination.href, { waitUntil: "domcontentloaded", timeout: timeoutMs });
      return;
    }
    case "chapter": {
      const title = boundedString(step.title, "chapter title", 120);
      const description = step.description ? boundedString(step.description, "chapter description", 300) : undefined;
      await page.screencast.showChapter(title, { description, duration: 600 });
      return;
    }
    case "fill": {
      const selector = boundedString(step.selector, "selector", 512);
      const value = boundedString(step.value, "fill value", 2048);
      await page.locator(selector).first().fill(value, { timeout: timeoutMs });
      return;
    }
    case "click": {
      const selector = boundedString(step.selector, "selector", 512);
      await page.locator(selector).first().click({ timeout: timeoutMs });
      return;
    }
    case "expect_text": {
      const selector = boundedString(step.selector, "selector", 512);
      const text = boundedString(step.text, "expected text", 2048);
      await page.locator(selector).filter({ hasText: text }).first().waitFor({ state: "visible", timeout: timeoutMs });
      return;
    }
    case "expect_visible": {
      const selector = boundedString(step.selector, "selector", 512);
      await page.locator(selector).first().waitFor({ state: "visible", timeout: timeoutMs });
      return;
    }
    case "screenshot": {
      const name = safeSegment(step.name, "screenshot name");
      await ensureDirectory(screenshotDirectory);
      const filename = `${String(ordinal).padStart(2, "0")}-${name}.png`;
      const screenshotPath = path.join(screenshotDirectory, filename);
      await page.screenshot({ path: screenshotPath, animations: "disabled" });
      artifacts.push({
        kind: "screenshot",
        path: path.join("screenshots", filename),
        mediaType: "image/png",
      });
      return;
    }
    case "wait": {
      const duration = step.duration_ms;
      if (!Number.isInteger(duration) || duration < 0 || duration > 2_000) {
        throw new Error("wait duration is outside the bounded range");
      }
      await page.waitForTimeout(duration);
      return;
    }
    default:
      throw new Error(`unsupported proof action: ${action}`);
  }
}

async function regularNonempty(filePath) {
  try {
    const metadata = await stat(filePath);
    return metadata.isFile() && metadata.size > 0;
  } catch {
    return false;
  }
}

export async function runProof(input) {
  const initialResourceUsage = process.resourceUsage();
  const issueId = safeSegment(input.issueId, "issue_id");
  const runId = safeSegment(input.runId, "run_id");
  const target = validateTargetUrl(input.targetUrl, input.allowedHosts ?? []);
  const viewport = validateViewport(input.viewport);
  const steps = input.steps ?? [];
  if (!Array.isArray(steps) || steps.length === 0 || steps.length > MAX_STEPS) {
    throw new Error(`proof must contain between 1 and ${MAX_STEPS} steps`);
  }
  if (!steps.some((step) => step?.action === "expect_text" || step?.action === "expect_visible")) {
    throw new Error("proof must contain at least one deterministic assertion");
  }
  if (!hasPostInteractionAssertion(steps)) {
    throw new Error("proof must contain a post-interaction assertion");
  }
  const maxDurationMs = input.maxDurationMs ?? 60_000;
  if (!Number.isInteger(maxDurationMs) || maxDurationMs < 1_000 || maxDurationMs > MAX_DURATION_MS) {
    throw new Error("proof duration is outside the bounded range");
  }
  if (typeof input.expectedCommit !== "string" || !/^[a-f0-9]{40,64}$/.test(input.expectedCommit)) {
    throw new Error("expectedCommit is required");
  }
  if (!/^[a-f0-9]{64}$/.test(input.acceptanceCriteriaSha256 ?? "")) {
    throw new Error("acceptanceCriteriaSha256 is required");
  }
  if (!/^[a-f0-9]{64}$/.test(input.workflowSha256 ?? "")) {
    throw new Error("workflowSha256 is required");
  }
  const proofPlanSha256 = sha256(
    canonicalJson({ schema_version: 1, viewport, max_duration_ms: maxDurationMs, steps }),
  );

  const repository = await repositoryFingerprint(input.repositoryRoot);
  if (repository.head !== input.expectedCommit) throw new Error("repository commit mismatch");
  if (repository.dirty && input.allowDirty !== true) throw new Error("repository working tree is dirty");

  const runRoot = await prepareRunRoot(input.stateRoot, issueId, runId);
  const videoPath = path.join(runRoot, "receipt.webm");
  const tracePath = path.join(runRoot, "trace.zip");
  const screenshotDirectory = path.join(runRoot, "screenshots");
  const artifacts = [];
  const stepResults = [];
  const diagnostics = { console_errors: [], failed_requests: [] };
  const allowedHosts = new Set((input.allowedHosts ?? []).map((host) => host.toLowerCase()));
  const started = Date.now();
  const startedAt = new Date(started).toISOString();
  let browser;
  let context;
  let page;
  let browserVersion = "unknown";
  let status = "passed";
  let failureOrdinal = null;
  let traceStarted = false;
  let screencastStarted = false;

  try {
    browser = await chromium.launch({ headless: true });
    browserVersion = browser.version();
    context = await browser.newContext({
      viewport,
      acceptDownloads: false,
      serviceWorkers: "block",
    });
    await context.tracing.start({ screenshots: true, snapshots: true, sources: false });
    traceStarted = true;
    page = await context.newPage();
    page.setDefaultTimeout(DEFAULT_STEP_TIMEOUT_MS);

    page.on("console", (message) => {
      if (message.type() === "error" && diagnostics.console_errors.length < 50) {
        diagnostics.console_errors.push(diagnosticFingerprint("console_error", message.text()));
      }
    });
    page.on("pageerror", (error) => {
      if (diagnostics.console_errors.length < 50) {
        diagnostics.console_errors.push(diagnosticFingerprint("page_error", `${error.name}: ${error.message}`));
      }
    });
    page.on("requestfailed", (request) => {
      if (diagnostics.failed_requests.length < 50) {
        diagnostics.failed_requests.push(
          requestFingerprint(request.url(), "request_failed", request.failure()?.errorText ?? "failed"),
        );
      }
    });
    await page.route("**/*", async (route) => {
      if (allowedRequest(route.request().url(), target, allowedHosts)) {
        await route.continue();
      } else {
        if (diagnostics.failed_requests.length < 50) {
          diagnostics.failed_requests.push(
            requestFingerprint(route.request().url(), "blocked_by_origin_policy"),
          );
        }
        await route.abort("blockedbyclient");
      }
    });
    await page.routeWebSocket(/.*/, async (socket) => {
      if (allowedWebSocket(socket.url(), target, allowedHosts)) {
        socket.connectToServer();
      } else {
        if (diagnostics.failed_requests.length < 50) {
          diagnostics.failed_requests.push(
            requestFingerprint(socket.url(), "blocked_websocket"),
          );
        }
        await socket.close({ code: 1008, reason: "blocked by proof origin policy" });
      }
    });

    await page.screencast.start({ path: videoPath, size: viewport });
    screencastStarted = true;
    await page.screencast.showActions({ position: "top-right", duration: 500, fontSize: 14 });

    for (const [index, step] of steps.entries()) {
      const ordinal = index + 1;
      const elapsed = Date.now() - started;
      const remaining = maxDurationMs - elapsed;
      if (remaining <= 0) {
        status = "failed";
        failureOrdinal = ordinal;
        stepResults.push(stepRecord(step, ordinal, false, 0, "proof_deadline_exceeded"));
        break;
      }

      const stepStarted = Date.now();
      try {
        await executeStep({
          page,
          target,
          step,
          ordinal,
          timeoutMs: Math.min(DEFAULT_STEP_TIMEOUT_MS, remaining),
          screenshotDirectory,
          artifacts,
        });
        stepResults.push(stepRecord(step, ordinal, true, Date.now() - stepStarted));
      } catch {
        status = "failed";
        failureOrdinal = ordinal;
        stepResults.push(stepRecord(step, ordinal, false, Date.now() - stepStarted, "step_failed"));
        await ensureDirectory(screenshotDirectory);
        const failurePath = path.join(screenshotDirectory, "failure.png");
        await page.screenshot({ path: failurePath, animations: "disabled" }).catch(() => {});
        if (await regularNonempty(failurePath)) {
          artifacts.push({
            kind: "failure_screenshot",
            path: path.join("screenshots", "failure.png"),
            mediaType: "image/png",
          });
        }
        break;
      }
    }
  } finally {
    if (screencastStarted) await page.screencast.stop().catch(() => {});
    if (traceStarted) await context.tracing.stop({ path: tracePath }).catch(() => {});
    if (context) await context.close().catch(() => {});
    if (browser) await browser.close().catch(() => {});
  }

  if (await regularNonempty(videoPath)) {
    artifacts.unshift({ kind: "video", path: "receipt.webm", mediaType: "video/webm" });
  }
  if (await regularNonempty(tracePath)) {
    artifacts.push({ kind: "trace", path: "trace.zip", mediaType: "application/zip" });
  }
  if (!artifacts.some((artifact) => artifact.kind === "video")) {
    throw new Error("proof video was not produced");
  }

  const finishedAt = new Date().toISOString();
  const finalResourceUsage = process.resourceUsage();
  const finalRepository = await repositoryFingerprint(input.repositoryRoot);
  if (!sameRepositoryFingerprint(repository, finalRepository)) {
    throw new Error("repository changed during proof capture");
  }
  const manifest = await createProofManifest({
    runRoot,
    issueId,
    runId,
    repository,
    target: target.origin,
    browser: { name: "chromium", version: browserVersion, backend: "playwright" },
    viewport,
    startedAt,
    finishedAt,
    status,
    proofPlanSha256,
    acceptanceCriteriaSha256: input.acceptanceCriteriaSha256,
    workflowSha256: input.workflowSha256,
    captureMetrics: {
      userCpuMs: Math.max(0, Math.round((finalResourceUsage.userCPUTime - initialResourceUsage.userCPUTime) / 1_000)),
      systemCpuMs: Math.max(0, Math.round((finalResourceUsage.systemCPUTime - initialResourceUsage.systemCPUTime) / 1_000)),
      processMaxRssBytes: Math.max(0, finalResourceUsage.maxRSS * 1_024),
    },
    steps: stepResults,
    diagnostics: {
      ...diagnostics,
      failure_ordinal: failureOrdinal,
    },
    artifacts,
  });

  return { runRoot, manifest };
}
