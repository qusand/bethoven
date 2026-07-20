#!/usr/bin/env node

import { lstat, readFile, realpath } from "node:fs/promises";
import path from "node:path";

import { runProof } from "../src/runner.mjs";
import { safeArtifactPath } from "../src/security.mjs";

function parseArguments(argv) {
  const values = { allowedHosts: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--allow-dirty") {
      values.allowDirty = true;
      continue;
    }
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`missing value for ${argument}`);
    index += 1;
    switch (argument) {
      case "--spec": values.spec = value; break;
      case "--state-root": values.stateRoot = value; break;
      case "--repository-root": values.repositoryRoot = value; break;
      case "--target": values.targetUrl = value; break;
      case "--expected-commit": values.expectedCommit = value; break;
      case "--acceptance-criteria-sha256": values.acceptanceCriteriaSha256 = value; break;
      case "--workflow-sha256": values.workflowSha256 = value; break;
      case "--issue-id": values.issueId = value; break;
      case "--run-id": values.runId = value; break;
      case "--allowed-host": values.allowedHosts.push(value); break;
      default: throw new Error(`unknown argument: ${argument}`);
    }
  }
  for (const field of [
    "spec",
    "stateRoot",
    "repositoryRoot",
    "targetUrl",
    "expectedCommit",
    "acceptanceCriteriaSha256",
    "workflowSha256",
    "issueId",
    "runId",
  ]) {
    if (!values[field]) throw new Error(`missing required argument: ${field}`);
  }
  return values;
}

async function readBoundedSpec(repositoryRoot, specPath) {
  const canonicalRepository = await realpath(repositoryRoot);
  const absoluteInput = path.resolve(specPath);
  const relation = path.relative(canonicalRepository, absoluteInput);
  const safePath = await safeArtifactPath(canonicalRepository, relation);
  const metadata = await lstat(safePath);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > 64 * 1024) {
    throw new Error("proof spec must be a regular file of at most 64 KiB");
  }
  const spec = JSON.parse(await readFile(safePath, "utf8"));
  const allowedKeys = new Set(["steps", "viewport", "max_duration_ms"]);
  if (!spec || typeof spec !== "object" || Array.isArray(spec)) throw new Error("proof spec must be an object");
  for (const key of Object.keys(spec)) {
    if (!allowedKeys.has(key)) throw new Error(`unsupported proof spec field: ${key}`);
  }
  return spec;
}

try {
  const args = parseArguments(process.argv.slice(2));
  const spec = await readBoundedSpec(args.repositoryRoot, args.spec);
  const result = await runProof({
    stateRoot: path.resolve(args.stateRoot),
    repositoryRoot: path.resolve(args.repositoryRoot),
    targetUrl: args.targetUrl,
    expectedCommit: args.expectedCommit,
    acceptanceCriteriaSha256: args.acceptanceCriteriaSha256,
    workflowSha256: args.workflowSha256,
    issueId: args.issueId,
    runId: args.runId,
    allowDirty: args.allowDirty === true,
    allowedHosts: args.allowedHosts,
    viewport: spec.viewport,
    maxDurationMs: spec.max_duration_ms,
    steps: spec.steps,
  });
  process.stdout.write(`${JSON.stringify({
    status: result.manifest.status,
    manifest_path: path.join(result.runRoot, "manifest.json"),
    manifest_sha256: result.manifest.manifest_sha256,
    model_tokens: result.manifest.accounting.model_tokens,
  })}\n`);
  if (result.manifest.status !== "passed") process.exitCode = 2;
} catch (error) {
  process.stderr.write(`bethoven-proof failed: ${error.name === "SyntaxError" ? "invalid_spec_json" : "proof_error"}\n`);
  process.exitCode = 1;
}
