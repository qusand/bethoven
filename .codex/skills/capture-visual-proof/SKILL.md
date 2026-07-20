---
name: capture-visual-proof
description: Record and validate a bounded, assertion-backed Bethoven UI proof packet. Use for user-facing changes that require a browser walkthrough, screenshot, trace, or video evidence before human review; also use when verifying that proof generation adds no model-token consumption.
---

# Capture visual proof

Read `proof/README.md` before the first use in a checkout.

## Preconditions

1. Commit the candidate change and require a clean worktree. Do not use `--allow-dirty` unless an
   operator explicitly authorizes a diagnostic run.
2. Require host-provided issue ID, run ID, expected commit, workflow SHA-256,
   acceptance-criteria SHA-256, state root, target origin, and app launch command. Never invent or
   accept tracker identity, destination state, credentials, or arbitrary host paths from
   model-generated step data.
3. Use an isolated non-production account and seeded data. Treat every pixel and trace as potentially
   sensitive.
4. Skip visual proof for changes with no meaningful user-visible behavior.

## Build the step spec

Create one JSON file inside the bound repository. Permit only `steps`, `viewport`, and
`max_duration_ms`. Prefer the shortest end-to-end path that proves the ticket acceptance criterion.

Use only these actions:

- `goto`: same-origin relative path.
- `chapter`: short reviewer-facing title and optional description.
- `fill` and `click`: deterministic CSS selector plus bounded input.
- `expect_text` and `expect_visible`: objective success checks.
- `screenshot`: final or materially distinct state.
- `wait`: at most 2 seconds and only when no deterministic readiness signal exists.

Include at least one objective assertion after the changed interaction. Do not use video appearance
as the assertion.

## Record

Start the app with the repository-approved host command and wait for its health signal. Then invoke
the runner with host bindings:

```sh
node proof/bin/bethoven-proof.mjs \
  --spec "$BETHOVEN_PROOF_SPEC" \
  --state-root "$BETHOVEN_STATE_ROOT" \
  --repository-root "$BETHOVEN_REPOSITORY_ROOT" \
  --target "$BETHOVEN_TARGET_URL" \
  --expected-commit "$BETHOVEN_EXPECTED_COMMIT" \
  --acceptance-criteria-sha256 "$BETHOVEN_ACCEPTANCE_CRITERIA_SHA256" \
  --workflow-sha256 "$BETHOVEN_WORKFLOW_SHA256" \
  --issue-id "$BETHOVEN_ISSUE_ID" \
  --run-id "$BETHOVEN_RUN_ID"
```

Fail closed when a binding is absent. Stop the app process group after capture, including on failure.

## Consume evidence economically

Read only the runner's compact JSON result and, when needed, narrow manifest fields. Do not load the
WebM, screenshots, trace ZIP, DOM snapshots, or full browser logs into model context.

Report:

- pass/fail and assertion count;
- manifest path and SHA-256;
- bound commit and dirty flag;
- video bytes and duration;
- `model_tokens` for the recording harness;
- any blocked publication or failed assertion.

Never call a failed packet “proof of success.” Preserve its failure packet when capture reached the
browser; browser-launch and storage failures may terminate before a packet can be formed.

## Publish

Do not invoke `bethoven-publish-linear` from an untrusted agent session. Publication is a host-owned
side effect and requires the scheduler-bound Linear issue UUID, review-state UUID, journal root, and
credential. Request the narrow host publisher when it is available. Until scheduler integration is
complete, attach the local manifest path/hash to the handoff and leave the issue state unchanged.

Never upload traces or screenshots to Linear. The publisher uploads only the verified video and may
transition only after bounded marker reconciliation confirms the comment. Do not describe Linear
comment creation itself as idempotent.
