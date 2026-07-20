# Bethoven agent guide

Bethoven is the measured fork of OpenAI Symphony in this checkout. Before architecture, token-cost,
or ecosystem work, read [`docs/knowledge/README.md`](docs/knowledge/README.md) and follow
[`docs/knowledge/AGENTS.md`](docs/knowledge/AGENTS.md). Those files are the canonical current thesis;
Git history is the archive. Replace disproven claims instead of accumulating dated or competing
documents.

Keep these boundaries explicit:

- distinguish pinned-upstream behavior from unmerged Bethoven changes;
- label evidence as observed, inferred, recommended, or not verified;
- measure accepted, verified outcomes per total issue token—not prompt size alone;
- never load videos, screenshots, traces, or verbose logs into model context when a compact manifest
  or scalar result is available;
- keep tracker writes and proof publication host-bound, narrow, durable, and fail-closed;
- do not claim live Linear, production, cross-host, or review-efficiency validation until it has
  actually been run.

For user-visible changes, use the repository skill
[`$capture-visual-proof`](.codex/skills/capture-visual-proof/SKILL.md) only after objective tests pass.
The standalone proof runner is under [`proof/`](proof/README.md). Nested instructions in
[`elixir/AGENTS.md`](elixir/AGENTS.md) apply to the reference implementation.
