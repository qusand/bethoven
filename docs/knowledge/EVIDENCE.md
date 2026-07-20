---
status: canonical
upstream_ref: 7af5a7648c9fbffa08825fe0c0b18be00100aff3
verified_on: 2026-07-20
---

# Evidence ledger

Use this file to verify claims without reloading the whole repository or research trail.

Classifications:

- **Observed**: directly supported by source, protocol schema, or first-party project material.
- **Inference**: reasoned conclusion from observed evidence; alternatives remain possible.
- **Recommendation**: proposed action, not current behavior.
- **Not verified**: material uncertainty that has not been resolved.

Entries E-001 through E-020 distinguish the pinned upstream ref from the Bethoven working tree.
Where an upstream entry cites a local source path plus line numbers, the numbers refer to
`7af5a7648c9fbffa08825fe0c0b18be00100aff3`; after local edits, inspect that exact version with
`git show 7af5a7648c9fbffa08825fe0c0b18be00100aff3:<path>` rather than assuming the current line
occupies the same number.

## E-001

**Observed — pinned source baseline.** Local `HEAD` and `upstream/main` were
`7af5a7648c9fbffa08825fe0c0b18be00100aff3`, “Add generic tracker interface with Linear adapter
(#102),” when researched on 2026-07-20. Upstream had 31 commits; tag `v0.0.1` points to `91a6249`, two
commits earlier.

Sources: [upstream commit](https://github.com/openai/symphony/commit/7af5a7648c9fbffa08825fe0c0b18be00100aff3),
[v0.0.1](https://github.com/openai/symphony/releases/tag/v0.0.1), local `git rev-parse HEAD`, local
`git describe --tags --always` (`v0.0.1-2-g7af5a76`).

## E-002

**Observed — public purpose and scope.** OpenAI says Symphony turns a tracker such as Linear into a
work control plane, publishes a minimal language-neutral specification and experimental Elixir
reference, does not plan to maintain it as a standalone product, and expects others to implement
their own versions. The spec defines a scheduler/runner and tracker reader, and explicitly excludes
a rich UI, multi-tenant control plane, distributed job system, and general workflow engine.

Sources: [OpenAI announcement](https://openai.com/pl-PL/index/open-source-codex-orchestration-symphony/),
[upstream README](https://github.com/openai/symphony), [local SPEC.md](../../SPEC.md) lines 46-69.

**Uncertainty:** OpenAI's reported 500%/sixfold accepted-PR increase is a first-party early
operational claim, not an independently reproduced controlled study.

## E-003

**Observed — supervision and authority.** The application supervisor starts PubSub,
`WorkflowStore`, `AgentRuntimeSupervisor`, optional HTTP, and dashboards. The runtime supervisor
wraps `Task.Supervisor` and `Orchestrator` with `:one_for_all`. The orchestrator keeps claims,
running/blocked/retry entries, polling state, and token totals in its process state.

Sources: [`symphony_elixir.ex`](../../elixir/lib/symphony_elixir.ex) lines 35-50;
[`agent_runtime_supervisor.ex`](../../elixir/lib/symphony_elixir/agent_runtime_supervisor.ex) lines
15-33; [`orchestrator.ex`](../../elixir/lib/symphony_elixir/orchestrator.ex) lines 17-44.

## E-004

**Observed — dispatch, retry, and reconciliation.** A tick reconciles existing work, validates
config, fetches and orders candidates, applies eligibility/capacity, revalidates selected IDs, and
starts supervised tasks. Normal worker exit with an active issue schedules a one-second
continuation. Failures use exponential backoff. Running, retry, blocked, and aggregate usage state
is not durable.

Sources: [`orchestrator.ex`](../../elixir/lib/symphony_elixir/orchestrator.ex) lines 83-126, 128-253,
256-307, 421-580, 582-779, 782-1012, 1022-1206; [SPEC.md](../../SPEC.md) lines 1688-1767.

## E-005

**Observed — session and turn lifecycle.** One `AgentRunner` invocation starts one app-server and
always calls `thread/start`. Turn one receives the fully rendered workflow prompt. Later turns on
that worker reuse the thread and receive a short continuation. `max_turns` applies inside the
worker. A new continuation/retry worker gets no prior thread ID, so it starts fresh.

Sources: [`agent_runner.ex`](../../elixir/lib/symphony_elixir/agent_runner.ex) lines 88-170;
[`app_server.ex`](../../elixir/lib/symphony_elixir/codex/app_server.ex) lines 277-368;
[`orchestrator.ex`](../../elixir/lib/symphony_elixir/orchestrator.ex) lines 928-979, 1195-1205.

**Inference:** an issue that remains active can create an unbounded number of fresh sessions because
no cross-worker session, turn, token, credit, or wall-time cap appears in orchestrator state or the
agent schema.

## E-006

**Observed — tracker seam and mutation tool.** The scheduler consumes normalized issues and generic
reads. The registry contains Linear and an in-memory adapter. Linear exposes raw `linear_graphql` as
a dynamic Codex tool; host-side execution keeps credentials out of the child environment. The tool
does not enforce a field/page/result-byte budget, mutation idempotency, project scope, or retry
policy.

Sources: [`tracker.ex`](../../elixir/lib/symphony_elixir/tracker.ex) lines 13-81;
[`issue.ex`](../../elixir/lib/symphony_elixir/tracker/issue.ex) lines 12-60;
[`linear/adapter.ex`](../../elixir/lib/symphony_elixir/linear/adapter.ex) lines 11-46;
[`linear/agent_tool.ex`](../../elixir/lib/symphony_elixir/linear/agent_tool.ex) lines 12-66, 114-146;
[`app_server.ex`](../../elixir/lib/symphony_elixir/codex/app_server.ex) lines 194-259, 589-760.

## E-007

**Observed — workflow and hot reload.** `WORKFLOW.md` is typed YAML configuration plus a Solid
prompt template. `WorkflowStore` polls its content stamp, accepts valid replacements, and preserves
the last valid workflow after reload errors. Later operations see new config, but running app-server
sessions are not restarted.

Sources: [`workflow.ex`](../../elixir/lib/symphony_elixir/workflow.ex) lines 10-114;
[`workflow_store.ex`](../../elixir/lib/symphony_elixir/workflow_store.ex) lines 65-180;
[`config/schema.ex`](../../elixir/lib/symphony_elixir/config/schema.ex) lines 304-346, 398-464,
493-590; [`prompt_builder.ex`](../../elixir/lib/symphony_elixir/prompt_builder.ex) lines 10-63.

## E-008

**Observed — workspaces, persistence, and trust.** Workspaces are deterministic and retained across
ordinary retries. Local path containment is enforced; remote checks are weaker. VCS bootstrap and
delivery behavior are hook/agent responsibilities. Hooks run arbitrary shell. The project labels
itself a trusted-environment engineering preview. HTTP routes show no authentication layer at the
pinned ref.

Sources: [`workspace.ex`](../../elixir/lib/symphony_elixir/workspace.ex) lines 15-253, 403-443;
[`path_safety.ex`](../../elixir/lib/symphony_elixir/path_safety.ex) lines 4-49;
[`ssh.ex`](../../elixir/lib/symphony_elixir/ssh.ex) lines 4-49;
[`README.md`](../../README.md) lines 13-14; [`elixir/README.md`](../../elixir/README.md) lines 141-178;
[`router.ex`](../../elixir/lib/symphony_elixir_web/router.ex) lines 25-40.

## E-009

**Observed — usage and observability.** The daemon exposes live aggregate and running-worker usage,
runtime, retries, and rate-limit snapshots through logs/dashboards/API. Totals live in orchestrator
memory. Completed per-issue session history, prompt/model/tool dimensions, cached/reasoning tokens,
and quality outcomes are not retained. The accounting implementation falls back to
`turn/completed` usage although its accounting guide warns generic completion usage may not be a
cumulative thread total.

Sources: [`orchestrator.ex`](../../elixir/lib/symphony_elixir/orchestrator.ex) lines 1371-1498,
1471-1760; [`token_accounting.md`](../../elixir/docs/token_accounting.md) lines 14-20, 205-263;
[`observability_api_controller.ex`](../../elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex)
lines 11-62; [`presenter.ex`](../../elixir/lib/symphony_elixir_web/presenter.ex) lines 8-88.

Related open work: [PR #60, persist per-issue token usage](https://github.com/openai/symphony/pull/60)
proposes a JSONL ledger but was open, unmerged, stale, and conflicted when checked. Its existence is
evidence of interest, not of upstream behavior.

## E-010

**Observed — documentation/specification contradictions at the baseline.**

| Claim | Source A | Source B |
|---|---|---|
| Basic run command versus mandatory acknowledgement | [`elixir/README.md`](../../elixir/README.md) lines 63-73 | [`cli.ex`](../../elixir/lib/symphony_elixir/cli.ex) lines 111-126 |
| Relative workspace root resolution | [SPEC.md](../../SPEC.md) lines 557-559 | [`config/schema.ex`](../../elixir/lib/symphony_elixir/config/schema.ex) lines 504-536, 603-609 |
| Observability front matter called future work | [SPEC.md](../../SPEC.md) lines 2231-2241 | [`config/schema.ex`](../../elixir/lib/symphony_elixir/config/schema.ex) lines 252-270 |
| Claimed 100% project coverage versus exclusions | [`mix.exs`](../../elixir/mix.exs) lines 11-46 | Core runtime exclusion list in the same config |

## E-011

**Observed — example prompt and runtime cost posture.** The example workflow uses a 5-second poll,
global concurrency 10, 20 turns, `gpt-5.5`, `xhigh`, network access, and no approvals. Its Markdown
body at the pinned ref is 18,253 bytes and 2,798 whitespace words before issue substitution. It
contains all-state procedures and tells the agent both to consume embedded issue context and fetch
current tracker context.

Sources: [`elixir/WORKFLOW.md`](../../elixir/WORKFLOW.md) lines 18-39, 42-77, 118-185, 220-251;
local measurements with `wc` over body lines 42-329.

**Not verified:** exact tokenizer count, hidden Codex instructions, actual cached input, reasoning
tokens, credits, or production task distribution.

## E-012

**Observed, version-specific — current Codex protocol capabilities.** Official app-server docs and a
locally generated experimental JSON schema from `codex-cli 0.145.0-alpha.18` expose
`thread/resume`, `thread/compact/start`, and thread goal operations; the schema's goal object includes
objective, status, and token budget fields.

Sources: [Codex app-server API overview](https://learn.chatgpt.com/docs/app-server#api-overview);
local command `codex app-server generate-json-schema --out <temporary-directory> --experimental`.

**Boundary:** this proves current local capabilities, not compatibility with Symphony's pinned
app-server assumptions, stable billing behavior, or a net efficiency gain.

## E-013

**Observed — upstream resume experiment and revert.** [PR #84](https://github.com/openai/symphony/pull/84)
added thread links, ownership, archive behavior, and Linear-comment-driven resume and was merged on
2026-06-01. [PR #85](https://github.com/openai/symphony/pull/85) reverted it minutes later. Neither
the pull requests nor visible discussion provides a verified technical reason.

Local commits: `68a18a7` added the change; `fecbc92` reverted it.

**Not verified:** why it was reverted. Do not cite the revert as proof that thread resume is
architecturally invalid.

## E-014

**Observed — descendant survey, accessed 2026-07-20.** Meaningful direct forks and spec/architectural
ports include [Rondo](https://github.com/sandsower/rondo),
[Fifony](https://github.com/forattini-dev/fifony),
[Symphony++](https://github.com/Pimpmuckl/symphony-plus-plus),
[cc-symphony](https://github.com/hawkymisc/cc-symphony),
[OpenSymphony](https://github.com/kumanday/OpenSymphony),
[Symphony Restate](https://github.com/ACNoonan/symphony-restate),
[Kata Symphony](https://github.com/gannonh/kata-symphony),
[oh-my-symphony](https://github.com/cskwork/oh-my-symphony), and
[Beethoven](https://github.com/lucasacoutinho/beethoven).

Classification is based on GitHub ancestry plus project READMEs/history. Feature and maturity claims
are project-owned. No common independent task/cost benchmark was found.

## E-015

**Observed sources; recommendation is ours — durable execution.**
[Temporal](https://docs.temporal.io/workflow-execution) documents persisted workflow event history
and replay. [LangGraph checkpoints](https://langchain-ai.github.io/langgraph/reference/checkpoints/)
document persisted intermediate writes and resume. Symphony can apply the pattern to issue/run
identity, retry deadlines, thread metadata, verified artifacts, and side-effect boundaries.

**Tradeoff:** nondeterministic model calls and external mutations must be isolated behind idempotent
activities; replay, schema migration, and retention add operational complexity.

## E-016

**Observed sources; recommendation is ours — context engineering.**

- [OpenAI harness engineering](https://openai.com/index/harness-engineering/) advocates a short
  repository map and structured versioned artifacts as the system of record.
- [Anthropic context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
  advocates progressive disclosure, structured external notes, focused subagents, and compaction.
- [OpenAI compaction](https://developers.openai.com/api/docs/guides/compaction) describes preserving
  key conversation state in a smaller context.
- [Aider repository map](https://aider.chat/docs/repomap.html) selects graph-ranked repository
  symbols to an explicit token budget.
- [OpenAI prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching) depends on
  exact shared prefixes and reports cache-related usage.

These techniques require trace-level evaluation in Symphony. Retrieval can miss, memory can drift,
compaction can lose constraints, and cache economics depend on protocol/model behavior.

## E-017

**Observed sources; recommendation is ours — routing, tools, handoffs, and evals.**

- [OpenAI Agents SDK handoffs](https://openai.github.io/openai-agents-python/handoffs/) supports typed
  handoff data and history filtering.
- [RouteLLM](https://github.com/lm-sys/RouteLLM) and
  [FrugalGPT](https://arxiv.org/abs/2305.05176) show model-routing/cascade approaches, but not a
  validated Symphony coding-task policy.
- [SWE-agent's agent-computer interface](https://github.com/SWE-agent/SWE-agent/blob/main/docs/background/aci.md)
  and [paper](https://arxiv.org/abs/2405.15793) motivate bounded views, succinct output, and
  edit-time feedback.
- [OpenAI agent evals](https://developers.openai.com/api/docs/guides/agent-evals) and
  [Agents SDK tracing](https://openai.github.io/openai-agents-python/tracing/) motivate repeatable
  end-to-end traces and graders.

**Boundary:** routing results from general benchmarks do not establish coding-agent economics;
traces can contain secrets; automated graders must be paired with objective tests and accepted
outcomes.

## E-018

**Observed — Odysseus direct fork, reclassified 2026-07-20.**
[odysseus0/symphony](https://github.com/odysseus0/symphony) is not an unchanged network snapshot.
GitHub's cross-fork comparison at inspection time reported its `main` as four commits ahead and 25
commits behind upstream `main`, with merge base `b1863e83` and fork head `e812909d` from 2026-03-12.
The four fork commits add:

- an `.agents` Linear skill with prebuilt narrow GraphQL patterns and an explicit ban on schema
  introspection ([commit `6d42325`](https://github.com/odysseus0/symphony/commit/6d423256dd8f93034d5fc74764945fc64a50ef8a));
- a setup/onboarding skill and fork-specific README
  ([commit `7cda7a5`](https://github.com/odysseus0/symphony/commit/7cda7a54510e962724126423d0168284567c99f8));
- a file-backed `sync_workpad` dynamic tool
  ([commit `e812909`](https://github.com/odysseus0/symphony/commit/e812909ddb56bbf6a24155a2250686c5a8d5d894));
- a workflow change setting `thread_sandbox` to `danger-full-access` and
  `turn_sandbox_policy.type` to `dangerFullAccess`, plus native Linear media guidance and a PR
  cleanup hook ([commit `d90560a`](https://github.com/odysseus0/symphony/commit/d90560a3a720aa91476f361e1e52e51970a4e858)).

**Observed safety boundary:** `sync_workpad` accepts model-supplied `issue_id` and `file_path`, then
calls `File.read(path)` without canonical workspace containment, a known-filename policy, a body-size
limit, or a trusted binding to the running issue. It can therefore transmit arbitrary host-readable
file contents to a Linear comment, subject only to process and provider limits, if invoked with that
path. Tests cover valid, empty, and missing paths, but not path escape. The workflow's full-access
thread and turn policies enlarge this risk.

**Inference/recommendation:** the fork is a useful idea donor for onboarding and lean Linear
interactions, but it should not replace the current upstream base wholesale. Port narrow operations
onto current upstream with workspace/issue/size binding and retain a least-privilege sandbox. No
independent before/after token or accepted-work benchmark was found, so its efficiency claims remain
unverified until measured with the cost-capped protocol in [TOKEN-EFFICIENCY.md](TOKEN-EFFICIENCY.md#cost-capped-evaluation-protocol).

## E-019

**Observed — OpenAI's public visual-proof boundary.** OpenAI says requesters receive a review packet
with a video walkthrough in the real product, that its harness gained end-to-end tests, Chrome
DevTools app driving, and QA smoke tests, and that its internal demo attached a proof-of-work video.
The article does not say Chrome DevTools performed the recording or disclose a recording skill,
packet schema, upload transaction, or recovery protocol.

The pinned upstream checkout describes walkthrough videos in its README and its original
`elixir/WORKFLOW.md` required `launch-app` plus `github-pr-media`, although neither named skill was
present in the published repository. Bethoven replaces that unresolved instruction with its local
`capture-visual-proof` skill and keeps publication host-gated. The included upstream Linear skill
does document `fileUpload` → server `PUT` → comment creation. The spec keeps ticket writes in agent
tools/workflow rather than the scheduler kernel.

Pinned-tree verification used `git show 7af5a7648c9fbffa08825fe0c0b18be00100aff3:elixir/WORKFLOW.md`
to confirm the line-218 instruction and `git ls-tree -r --name-only 7af5a7648c9fbffa08825fe0c0b18be00100aff3 -- .codex/skills`
to confirm neither named skill was shipped at that ref.

Sources: [OpenAI Symphony article](https://openai.com/index/open-source-codex-orchestration-symphony/),
[`README.md`](../../README.md) lines 9-11, [`elixir/WORKFLOW.md`](../../elixir/WORKFLOW.md) lines
159-225, [`.codex/skills/capture-visual-proof/SKILL.md`](../../.codex/skills/capture-visual-proof/SKILL.md)
lines 78-84, [`.codex/skills/linear/SKILL.md`](../../.codex/skills/linear/SKILL.md) lines 337-383,
[SPEC.md](../../SPEC.md) lines 1352-1364.

**Inference:** Gemini's high-level harness explanation is directionally correct, but the claim that
a Chrome DevTools skill itself recorded and assembled the video is not proven by public OpenAI
material.

## E-020

**Observed sources; recommendation is ours — a modern implementation path.** Playwright's current
first-party APIs record videos, traces, action annotations, chapter overlays, and explicitly
describe “agentic video receipts.” Trace Viewer retains action, DOM, console, network, and filmstrip
evidence. Chrome DevTools MCP can automate and inspect Chrome and now exposes screencast tools, but
its own documentation warns that clients can inspect browser contents, remote debugging permits
local control, persistent profiles share state, usage telemetry is on by default, and network-header
redaction is opt-in.

Linear's official API supports server-side video upload via `fileUpload` and a signed `PUT`, issue
comments and state updates, and URL-idempotent issue attachments. Its newer Agent Session APIs expose
agent activities and external URLs but remain a developer preview.

Linear documents idempotency for URL attachments, not for comment creation or orphaned uploads.
Bethoven's comment marker and publication journal are therefore a bounded recovery protocol, not a
claim that Linear comments themselves are idempotent.

Sources: [Playwright videos](https://playwright.dev/docs/videos),
[Playwright v1.59 video receipts](https://playwright.dev/docs/release-notes),
[Playwright traces](https://playwright.dev/docs/trace-viewer),
[Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp),
[Linear file upload](https://linear.app/developers/how-to-upload-a-file-to-linear),
[Linear attachments](https://linear.app/developers/attachments),
[Linear agent interaction](https://linear.app/developers/agent-interaction).

**Recommendation:** use direct Playwright assertions as the deterministic proof backend. Keep
Chrome DevTools as an optional debugging/performance adapter, not as the correctness oracle. Keep
media out of model context and put upload/comment/state writes behind a narrow host-owned publisher.

## E-021

**Observed — Bethoven visual-proof slice, verified locally 2026-07-20.** `proof/` now:

- rejects stale commits, dirty checkouts by default, traversal, symlinks, external origins, excess
  steps, assertion-free plans, long duration, oversized artifacts, and oversized viewport, and
  rejects a changed checkout when the post-capture root/commit/status/diff fingerprint differs;
- executes bounded Playwright actions and post-interaction assertions in an isolated browser
  context while blocking unapproved HTTP and WebSocket traffic;
- emits annotated WebM, trace ZIP, PNG evidence, a semantically validated canonical SHA-256
  manifest with exclusive file/directory sync, rollback, and paired-failure preservation,
  owner-only files, plan/workflow/acceptance/run/commit bindings, and compact zero-token, CPU,
  peak-RSS, media-byte, and assertion accounting;
- re-verifies artifact hashes and container signatures before publication, binds file identity and
  uploaded bytes to one open handle, rejects unsafe returned URLs/headers, and rejects dirty packets
  or mismatched host identities;
- uses a durable publication journal, failure-clean operation lock, bounded paginated comment-marker
  reconciliation, exact comment-receipt comparison, post-transition state verification, typed
  public operator failures, response-loss recovery, retryable definite pre-`PUT` failures, and
  fail-closed ambiguous post-attempt upload state; cleanup verifies the acquired lock inode,
  preserves replacement locks, and does not let handle-close warnings mask the primary publication
  outcome;
- implements the official Linear upload/comment/update flow, exercised only against a loopback
  mock server.

Evidence: [`proof/README.md`](../../proof/README.md), [`proof/src`](../../proof/src), and
`npm test` in `proof/`: 43 tests passed, including a real headless Chromium recording, rejection
after a tracked file changes during capture or an upload path changes identity, injected manifest/
lock durability failures with paired-error preservation, replacement-lock preservation, retry after
definite pre-`PUT` failures, exact mutation-receipt checks, Markdown-safe asset rendering, unsafe
Linear slots with no `PUT`, and mock Linear side effects. The runner imports no model or Codex
client. “Zero model tokens” describes packet generation only; agent implementation and
acceptance-spec authoring can still consume model tokens.

A fresh diagnostic packet, `BETHOVEN-DEMO/research-20260720-002`, passed 8/8 steps with three
assertions in 3,135 ms. It produced a 203,944-byte WebM, 269,480-byte PNG, and 4,022,278-byte trace;
compact accounting reported 519 ms user CPU, 179 ms system CPU, 187,514,880-byte process peak RSS,
4,495,702 artifact bytes, and zero recording-harness model tokens. Its canonical manifest hash is
`6dcdfbda0dc4feaa83c0954cdbd4b479fbe5a1817c471a5c9eb189beb0baa65d`. The repository was dirty,
so the packet is deliberately non-publishable. It proves the local capture mechanics, not a clean
real-feature change, checkout-bound app launch, or live Linear delivery.

The before/after checkout fingerprint is two-sample tamper detection. It cannot observe a mutation
that is exactly restored between samples or the narrow interval after the final sample, and it does
not causally bind the serving process to that checkout.

**Not verified:** live Linear publication, browser operation on remote/SSH workspaces, secrets absent
from arbitrary real-product pixels/traces, exact media reproducibility, a host-owned launch receipt
that causally binds the serving process to the checkout, scheduler integration, and reduced human
review time on a representative issue cohort.

## E-022

**Observed — Bethoven durable accounting and budget slice, current tree verified
2026-07-20.** Relative to upstream `7af5a764`, the Elixir runtime now contains:

- a schema-v4 DETS ledger with one checkpoint per issue, immutable canonical event identities,
  durable recovery intents, strict semantic/lifecycle validation, bounded display history, bounded
  recursive redaction, first-corruption preservation during rebuild, and restart-restored aggregate
  totals;
- one in-process writer per canonical ledger path plus owner-only root/leaf identity checks, durable
  workflow-to-state-root binding, workflow-relative explicit state roots, symlink/hard-link
  rejection, and fail-closed recovery; binding markers use a synced private temporary file, atomic
  no-overwrite hard-link publication, cleanup, and directory sync, with the root marker completed
  before its global workflow anchor;
- scheduler-owned issue/run identities and disabled-by-default cumulative ceilings for sessions,
  turns, canonical tokens, wall time, and consecutive failures;
- stale-run rejection, hot token/wall-time termination, and a caller-bound synchronous
  `turn_reserved` write after `thread/start` but before `turn/start`, with no double count when
  runtime session metadata arrives;
- durable local `budget_exhausted` state, full-vector usage-event identities, prompt hash/byte
  metadata, and explicit `unreconciled` shutdown markers when the Codex protocol cannot supply a
  final query.

Sources: [`run_ledger.ex`](../../elixir/lib/symphony_elixir/run_ledger.ex),
[`run_ledger/`](../../elixir/lib/symphony_elixir/run_ledger),
[`issue_budget.ex`](../../elixir/lib/symphony_elixir/issue_budget.ex),
[`sensitive_data.ex`](../../elixir/lib/symphony_elixir/sensitive_data.ex), and
[`orchestrator.ex`](../../elixir/lib/symphony_elixir/orchestrator.ex).

An independent current-tree check reproduced an acknowledged-event-loss case when the DETS leaf
pathname was replaced while its original handle remained open. The implementation now binds the
leaf device/inode only after DETS open/repair and rejects a changed identity before every public
writer request. The public regression proves the second event is not acknowledged and restart sees
the original version. A userspace identity-check-to-DETS-operation timing window remains because
DETS has no descriptor-bound/openat interface.

Verification used the repository-pinned Elixir 1.19.5/OTP 28.5 toolchain through `mise`:

- `make all`: passed setup, escript build, formatting, public-spec checks, strict Credo, coverage,
  and Dialyzer; Credo reported zero issues and Dialyzer reported zero errors;
- non-live suite: 346 passed, 2 excluded in the final full gate; the focused ledger/storage
  crash-recovery suite separately passed 50/50, including first-error preservation, partial
  temporary files, and published two-link recovery for both root and anchor markers;
- configured coverage gate: 100%. Stateful runtime/integration boundaries, including the ledger
  facade, storage, writer, writer supervisor, orchestrator, agent runner, and adapters, remain
  explicitly excluded under the pre-existing boundary-module convention. Their public seams and
  recovery paths have focused regression coverage; this is not a claim of whole-runtime 100%;
- proof package: 43 passed, including real headless Chromium capture, mutation-during-capture and
  upload-identity rejection, injected persistence and lock-ownership failures, retryable pre-`PUT`
  rejection, exact mutation-receipt verification, Markdown-safe asset rendering, and loopback mock
  Linear;
- dependency checks: Hex found no retired or security-advisory packages, and `pnpm audit --prod`
  found no known proof-runner vulnerabilities;
- repository hygiene: `git diff --check`, 125 relative Markdown links across 34 files, every `.mjs`
  syntax check, a high-confidence credential-pattern scan, and the repository skill validator
  passed;
- test state remained inside the ignored fixture root and was removed after the suite. A prior
  test-created home binding directory was moved intact to Trash before the clean runs.

Current SHA-256 fingerprints include `run_ledger.ex` `7b32b6694de2…`, storage `955341632d5f…`,
writer `e26094b994d9…`, projection `e483195f7c2b…`, orchestrator `b929fc58d2d7…`, app-server
`68aedf867367…`, sensitive-data boundary `131dee70f5b1…`, ledger regression tests
`fff2c576f02f…`, proof runner `12c6d30bd267…`, its mutation regression `413cec5a33bb…`, manifest
writer `2c411fd1f395…`, Linear adapter `82a63f34ba37…`, and publisher `e44116f7ec66…`.

**Boundary:** operate one Bethoven BEAM service per state root. There is no cross-process or
multi-node lease. No live E2E tracker run, live Linear publication, clean real-feature proof packet,
or representative token-cost cohort was executed.

## Not verified

- Production token, credit, cache, retry, stall, and completion distributions for OpenAI's or any
  descendant's deployment.
- Exact hidden prompt/tool-schema cost and tokenizer count for a Symphony-started Codex thread.
- Whether both duplicated dynamic-tool result fields enter model context.
- Exact reasoning-token and credit semantics for `xhigh` in the configured Codex version.
- Whether app-server threads remain resumable after Symphony stops the local process, across hosts,
  versions, and retention windows.
- The technical reason PR #84 was reverted.
- Long-command event cadence and real false-stall frequency.
- A verified token-to-credit mapping or cache billing policy through the app-server.
- Independent common benchmarks across upstream, Rondo, Fifony, OpenSymphony, Symphony++, Restate,
  or other descendants.
- Exhaustive review of the full GitHub fork network.
- Shipped status of the Symphony-style proposal in
  [NousResearch/hermes-agent #404](https://github.com/NousResearch/hermes-agent/issues/404).
- OpenAI's private video-capture, packet-assembly, upload, and recovery implementation.
- Live Linear behavior of Bethoven's proof publisher and its review-time benefit.

Resolve an item here only by updating the relevant evidence entry and rewriting any affected thesis
or recommendation. Git history preserves the prior uncertainty.
