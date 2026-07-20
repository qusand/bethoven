#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";

import { LinearProofAdapter } from "../src/linear.mjs";
import { PublicationError, publishProof } from "../src/publisher.mjs";

class CliError extends Error {
  constructor(publicCode, publicMessage, options = {}) {
    super(publicMessage, options);
    this.publicCode = publicCode;
    this.publicMessage = publicMessage;
  }
}

const ARGUMENT_FIELDS = new Map([
  ["--run-root", "runRoot"],
  ["--journal-root", "journalRoot"],
  ["--issue-id", "issueId"],
  ["--run-id", "runId"],
  ["--expected-commit", "expectedCommit"],
  ["--acceptance-criteria-sha256", "acceptanceCriteriaSha256"],
  ["--workflow-sha256", "workflowSha256"],
  ["--review-state-id", "reviewStateId"],
]);

function parseArguments(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--confirm-linear-write") {
      values.confirm = true;
      continue;
    }
    const field = ARGUMENT_FIELDS.get(argument);
    if (!field) throw new CliError("invalid_arguments", "unknown publication argument");
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      throw new CliError("invalid_arguments", `missing value for ${argument}`);
    }
    index += 1;
    values[field] = value;
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
    if (!values[field]) {
      throw new CliError("invalid_arguments", `missing required argument: ${field}`);
    }
  }
  if (!values.confirm) {
    throw new CliError("invalid_arguments", "--confirm-linear-write is required");
  }
  return values;
}

function publicFailure(error) {
  if (error instanceof CliError || error instanceof PublicationError) {
    return { code: error.publicCode, message: error.publicMessage };
  }
  return { code: "publication_error", message: "publication failed; inspect the durable journal before retrying" };
}

try {
  const args = parseArguments(process.argv.slice(2));
  if (!process.env.LINEAR_API_KEY) {
    throw new CliError("credentials_missing", "LINEAR_API_KEY is required");
  }
  const runRoot = path.resolve(args.runRoot);
  let manifest;
  try {
    manifest = JSON.parse(await readFile(path.join(runRoot, "manifest.json"), "utf8"));
  } catch (error) {
    throw new CliError("manifest_unreadable", "proof manifest could not be read or parsed", { cause: error });
  }
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
  const output = { status: result.status, operation_key: result.journal.operation_key };
  if (result.cleanup_warnings) output.cleanup_warnings = result.cleanup_warnings;
  process.stdout.write(`${JSON.stringify(output)}\n`);
} catch (error) {
  const failure = publicFailure(error);
  process.stderr.write(`bethoven-publish-linear failed [${failure.code}]: ${failure.message}\n`);
  process.exitCode = 1;
}
