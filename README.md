# Bethoven

Bethoven is our measured, safety-first fork of OpenAI Symphony. Symphony turns project work into
isolated, autonomous implementation runs, allowing teams to manage work instead of supervising
coding agents. Bethoven now experiments with a durable issue ledger, issue-lifetime execution
budgets, cost evidence, and assertion-backed visual proof without expanding the scheduler into a
general workflow engine.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Understanding and evolving Symphony

This checkout includes a source-backed, agent-maintained guide to the runtime, its boundaries,
the wider Symphony lineage, and a measured roadmap for reducing token use. Start with the
[Symphony knowledge hub](docs/knowledge/README.md).

The optional [visual proof runner](proof/README.md) records a short UI walkthrough only while
machine-checkable acceptance steps execute. Its browser harness consumes zero model tokens. A
separately gated publisher can attach a verified video to Linear, but unattended publication stays
disabled until the scheduler supplies a trusted run envelope and app-launch receipt and a disposable
live canary has passed.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
