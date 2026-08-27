# Cadence Plugin for Codex

This repository provides an [OpenAI Codex plugin](https://developers.openai.com/codex/plugins/build) for working with [Cadence](https://cadenceworkflow.io/) — the fault-tolerant, stateful workflow orchestration platform. It packages the `cadence-developer` Agent Skill for distribution through Codex.

> **Status:** Early development. The bundled skill targets the Go, Java, and Python SDKs (the Python SDK is alpha, so its coverage calls out gaps explicitly).

## Installation

You can install the full plugin through a Codex marketplace, or install just the skill directly with the `skills` CLI.

### Option A — Local marketplace (full plugin)

This repo ships a repo-scoped marketplace at [`.agents/plugins/marketplace.json`](.agents/plugins/marketplace.json) that points at the plugin in this repo. To install and test it locally in the ChatGPT desktop app:

1. Clone this repository.
2. Register the marketplace with Codex:

   ```bash
   codex plugin marketplace add /absolute/path/to/codex-plugin
   ```

   Alternatively, from the repo root, Codex reads `$REPO_ROOT/.agents/plugins/marketplace.json` automatically.
3. Restart the ChatGPT desktop app.
4. Open **Plugins**, choose the **Cadence (local)** marketplace, and install the **Cadence** plugin.

### Option B — Standalone skill via `npx skills`

If you only need the skill without the Codex plugin wrapper, install it directly with the [`skills` CLI](https://github.com/vercel-labs/add-skill):

```bash
# From a clone of this repo (project scope -> .agents/skills/):
npx skills add . -a codex

# Or globally (user scope -> ~/.codex/skills/):
npx skills add . -a codex -g
```

The skill content is also maintained upstream in [`cadence-workflow/ai-skills`](https://github.com/cadence-workflow/ai-skills), so you can install it from there too (for example `npx skills add cadence-workflow/ai-skills -a codex`).

## What's included

- **cadence-developer** skill — Comprehensive guidance for building, debugging, and operating Cadence applications: creating workflows, activities, and workers; handling signals, queries, and child workflows; debugging non-determinism errors; and implementing saga, versioning, and testing patterns across the Go, Java, and Python SDKs.

## How skill content stays in sync

The `skills/` directory in this repo is a **vendored copy** of the upstream skill. It is updated automatically:

- A maintainer can run the **Sync skills from ai-skills** workflow manually
  (`workflow_dispatch`), optionally pinning a specific upstream ref.
- A new release in `ai-skills` fires a `repository_dispatch` event that triggers
  the same workflow.

Either path runs [`scripts/sync-skills.sh`](scripts/sync-skills.sh), which fetches the upstream content, refreshes `skills/`, records provenance in [`.codex-plugin/skill-source.json`](.codex-plugin/skill-source.json), and opens a pull request for review.

Do not hand-edit files under `skills/` in this repo — they are overwritten on the next sync. See [common pitfalls](CONTRIBUTING.md#common-pitfalls) in the contributing guide.

## Other coding agents

Plugins for other coding agents (Cursor, Claude Code) follow this same template, each vendoring the skill from `ai-skills`.

## License

Apache 2.0 — see [`LICENSE`](LICENSE).
