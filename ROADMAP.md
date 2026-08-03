# Compass Roadmap

> Status: **pre-alpha → alpha**. Single maintainer, daily-driving the editor. Everything below
> is what we're building toward — in the open, so the community can steer it.

## Maturity gates

We are deliberately honest about where we are. Nothing gets pitched, marketed, or funded
until it's earned.

| Gate | Criteria | Status |
|---|---|---|
| **Pre-alpha** | Boots, local AI works, agent runs — for the maintainer | ✅ |
| **Alpha** | Builds from source, harness-tested agent loop, benchmarks published, public docs coherent | 🔄 **We are here** (stability pass in progress) |
| **Beta** | Tagged releases with working installer, weekly cadence, community issues triaged, first external contributors | ⏳ Next |
| **1.0** | Notarized builds, MCP support, agent permission model, benchmark report per release | ⏳ |
| **Funding** | Not sought until beta maturity. Sponsors, when they come, fund notarization first. | ⏳ |

## v1.0 — shipping now

- <100ms FIM completion, on-device
- Codebase RAG + semantic search (HNSW, Apple Neural Engine)
- Private local chat, fully offline
- Agentic cloud pipeline — Planner → Worker → QA, 20+ tools, harness-tested
- Your provider, your keys, your bill (OpenRouter, Kilo, DeepSeek, any OpenAI-compatible)

## v1.5 — next

- **FIM benchmarks published** — TTFT, tokens/sec, p50/p95, measured with the real 4B model
  (models already on disk; pending the stability merge)
- **MCP support** — with sane defaults, not a config maze (top community request across
  competing tools)
- **Agent permission model** — approval gates, read-only mode, sandboxed actions (the #1
  emerging safety concern in the space)
- **Harness expansion** — tool-loop regression tests for every agent fix (competitors' top
  pain is tool reliability; we intend to make it a non-issue)
- Remote sessions (SSH/SFTP)
- Project memory — learns your conventions
- Native Anthropic & OpenAI providers
- Deeper macOS integration (Shortcuts, Spotlight)
- Signed & notarized builds — funded by sponsors

## v2.0 — the standard

- Plugin SDK & extensions
- Parallel specialized agents with context handoff (top demand in Roo/Cline issue trackers)
- Benchmark reports in every release
- Custom model fine-tuning pipeline
- Team features — usage-based, not per-seat

## Where this roadmap comes from

- **Benchmarks we measured**: see [BENCHMARKS.md](BENCHMARKS.md) and the live page on the website.
- **Community demand research** (Aug 2026): top-discussed issues across Cline, Roo Code,
  Continue, Void, and Kilo, plus HN user voice. Provider freedom, tool-loop reliability,
  terminal integration, MCP, and agent safety are the recurring themes — the roadmap above
  answers each one.
- **Architecture truth**: local never orchestrates, cloud never completes. The two-pipeline
  boundary is a design law, not a roadmap item.

## How to influence it

- Open an issue with the `roadmap` label
- Discuss in [Discussions](https://github.com/jtrefon/compass/discussions)
- The maintainer answers in the open — every accepted item lands here with a source
