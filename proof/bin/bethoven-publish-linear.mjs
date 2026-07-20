#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";

import { LinearProofAdapter } from "../src/linear.mjs";
import { publishProof } from "../src/publisher.mjs";

function parseArguments(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--confirm-linear-write") {
      values.confirm = true;
      continue;
    }
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`missing value for ${argument}`);
    index += 1;
    switch (argument) {
      case "--run-root": values.runRoot = value; break;
      case "--journal-root": values.journalRoot = value; break;
      case "--issue-id": values.issueId = value; break;
      case "--run-id": values.runId = value; break;
      case "--expected-commit": values.expectedCommit = value; break;
      case "--acceptance-criteria-sha256": values.acceptanceCriteriaSha256 = value; break;
      case "--workflow-sha256": values.workflowSha256 = value; break;
      case "--review-state-id": values.reviewStateId = value; break;
      default: throw new Error(`unknown argument: ${argument}`);
    }
  }
  for (const field of [
    "runRoot",
    "journalRoot",
    "issueId",
    "runId",
    "expectedCommit",
    "acceptanceCriteriaSha256",
    "workflowSha256",
    "reviewStateId",
  ]) {
    if (!values[field]) throw new Error(`missing required argument: ${field}`);
  }
  if (!values.confirm) throw new Error("--confirm-linear-write is required");
  return values;
}

try {
  const args = parseArguments(process.argv.slice(2));
  if (!process.env.LINEAR_API_KEY) throw new Error("LINEAR_API_KEY is required");
  const runRoot = path.resolve(args.runRoot);
  const manifest = JSON.parse(await readFile(path.join(runRoot, "manifest.json"), "utf8"));
  const result = await publishProof({
    adapter: new LinearProofAdapter({ token: process.env.LINEAR_API_KEY }),
    journalRoot: path.resolve(args.journalRoot),
    runRoot,
    issueId: args.issueId,
    runId: args.runId,
    expectedCommit: args.expectedCommit,
    acceptanceCriteriaSha256: args.acceptanceCriteriaSha256,
    workflowSha256: args.workflowSha256,
    reviewStateId: args.reviewStateId,
    manifest,
  });
  process.stdout.write(`${JSON.stringify({ status: result.status, operation_key: result.journal.operation_key })}\n`);
} catch {
  process.stderr.write("bethoven-publish-linear failed: publication_error\n");
  process.exitCode = 1;
}
