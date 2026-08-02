export const SITE_TITLE = "Compass — The native AI IDE for macOS";
export const SITE_DESCRIPTION =
  "Compass is a Swift-native AI IDE for macOS: agentic coding with your own provider and keys, plus on-device RAG, FIM completion and local chat that work fully offline. ~200MB, MIT, no Electron, no lock-in.";

export const BASE_URL = "/compass";
export const SITE_URL = "https://jtrefon.github.io/compass";
export const REPO = "https://github.com/jtrefon/compass";
export const RELEASES = `${REPO}/releases`;

export const INSTALL_BREW =
  "brew install --cask https://raw.githubusercontent.com/jtrefon/compass/main/Casks/compass.rb";
/** The brew cask ships with v0.7 — the first release that builds Compass.app + compass.dmg */
export const BREW_AVAILABLE = "v0.7";

export const NAV = [
  { label: "Features", href: "/features" },
  { label: "Tech", href: "/tech" },
  { label: "Download", href: "/download" },
  { label: "Contributors", href: "/contributors" },
] as const;

export const SOCIAL = {
  github: REPO,
} as const;

export const LATEST_MACOS = "macOS 26 (Apple Silicon)";
export const LOCAL_MODEL = "4B on-device model via MLX";
export const REMOTE_PROVIDERS =
  "OpenRouter, Kilo, DeepSeek, Alibaba Cloud, and any OpenAI-compatible endpoint";

export const FEATURES_SHIPPING = [
  {
    title: "Real FIM completion",
    desc: "Ghost-text completion in <100ms from a 4B model running on your Mac via MLX. Not a remote round-trip. Not a fake heuristic.",
  },
  {
    title: "Private local chat",
    desc: "Ask questions, bounce ideas, get a second pair of eyes — entirely on-device. No API key, no network, no one listening.",
  },
  {
    title: "ANE-accelerated RAG",
    desc: "Embeddings and retrieval run on the Apple Neural Engine — indexing and search stay silent and painless, never hogging your CPU.",
  },
  {
    title: "Codebase intelligence",
    desc: "SQLite FTS5 plus HNSW vector retrieval over files, symbols, and chunks — grounded answers drawn from your own code.",
  },
  {
    title: "Agentic coding, your provider",
    desc: "Planner → Worker → QA orchestration with 20+ tools. Route through OpenRouter, Kilo, DeepSeek, Alibaba — or any OpenAI-compatible endpoint. Your key, your bill.",
  },
  {
    title: "Built-in terminal & browser",
    desc: "Read docs and run commands without leaving the editor. One app, zero context-switching.",
  },
  {
    title: "Inline AI popover",
    desc: "Cursor-anchored Q&A for instant explain, refactor, or ask — without losing your place in the code.",
  },
  {
    title: "Semantic search",
    desc: "HNSW ANN vector index with on-device embeddings — 10–50× faster than brute-force with ~95–99% recall.",
  },
] as const;

export const FEATURES_BETA = [
  {
    title: "Remote sessions",
    desc: "SSH and SFTP integration so the agent works in your infrastructure.",
  },
  {
    title: "Project memory",
    desc: "Adaptive rules and inspectable memories that teach the assistant your conventions per repository.",
  },
  {
    title: "Native Anthropic & OpenAI providers",
    desc: "Direct provider integrations — on the roadmap, not vapor. Until then, OpenRouter covers them through one key.",
  },
  {
    title: "Plugin SDK",
    desc: "Extensions for tools, languages, and workflows. The ecosystem question, answered in the open.",
  },
  {
    title: "Signed & notarized builds",
    desc: "Funded by sponsors — the $99/year Apple fee, paid by the community, so your Mac trusts us out of the box.",
  },
] as const;

export const PIPELINE_LOCAL = [
  { feature: "Latency", value: "<100ms (target — benchmarks published)" },
  { feature: "Model", value: "4B on-device LLM via MLX" },
  { feature: "Privacy", value: "100% offline — nothing leaves your machine" },
  { feature: "Tasks", value: "FIM completion, inline Q&A, semantic search, local chat" },
  { feature: "Network", value: "No internet required. Ever." },
  { feature: "Boundaries", value: "No orchestration, no tool loop — by design" },
];

export const PIPELINE_CLOUD = [
  { feature: "Latency", value: "Seconds (task-dependent)" },
  {
    feature: "Model",
    value:
      "Any provider — OpenRouter, Kilo, DeepSeek, Alibaba, or any OpenAI-compatible endpoint",
  },
  { feature: "Privacy", value: "Opt-in — you choose when code is sent" },
  {
    feature: "Tasks",
    value: "Agentic refactors, multi-file planning, tool orchestration, review",
  },
  { feature: "Network", value: "Requires internet — offline falls back to local" },
  {
    feature: "Boundaries",
    value: "Never runs inline completion — that's the local pipeline's job",
  },
];

export const COMPETITIVE = [
  { need: "Autocomplete latency", cloud: "500–2000ms, network-bound", us: "<100ms, on-device" },
  { need: "Working offline", cloud: "Dead without a connection", us: "Full offline tier — RAG, FIM, local chat" },
  { need: "Where your code goes", cloud: "Vendor's server, every keystroke", us: "Your Mac — unless you opt in" },
  { need: "Embeddings & RAG", cloud: "Cloud-bound, code ships out", us: "On-device, Apple Neural Engine" },
  {
    need: "Agentic tasks",
    cloud: "Strong, but locked to their models and pricing",
    us: "Same orchestration — your provider, your key, your cost",
  },
  { need: "Mac integration", cloud: "Electron — a browser in a window", us: "Native SwiftUI + AppKit, Liquid Glass" },
  { need: "Memory footprint", cloud: "1GB+ and climbing", us: "~200MB, AI included" },
  {
    need: "Cost & ownership",
    cloud: "$15–20/mo per seat — roadmap owned by a board",
    us: "Free. MIT. BYO keys. Nobody can sell it out from under you.",
  },
] as const;

export const ROADMAP = [
  {
    phase: "v1.0 — shipping now",
    items: [
      "<100ms FIM completion, on-device",
      "Codebase RAG + semantic search (HNSW, ANE)",
      "Private local chat, fully offline",
      "Agentic cloud pipeline — Planner → Worker → QA, 20+ tools",
      "Your provider, your keys, your bill",
    ],
  },
  {
    phase: "v1.5 — next",
    items: [
      "Published benchmarks (latency, RAM, index time)",
      "Remote sessions (SSH/SFTP)",
      "Project memory — learns your conventions",
      "Native Anthropic & OpenAI providers",
      "Deeper macOS integration (Shortcuts, Spotlight)",
      "Signed & notarized builds — funded by sponsors",
    ],
  },
  {
    phase: "v2.0 — the standard",
    items: [
      "Plugin SDK & extensions",
      "Benchmark reports in every release",
      "Custom model fine-tuning pipeline",
      "Team features — usage-based, not per-seat",
    ],
  },
] as const;

export const FAQ = [
  {
    q: "Is the agent as good as Cursor's?",
    a: "Agentic quality is the model you bring. Compass gives you the orchestration — Planner → Worker → QA with 20+ tools and stall detection — and you choose the brain: OpenRouter, Kilo, DeepSeek, Alibaba, or any OpenAI-compatible endpoint. Bring the best model in the world; we run it at native speed. Our orchestration is open and harness-tested — the tests are in the repo.",
  },
  {
    q: "It's not notarized — is it safe?",
    a: "MIT licensed, ~40k lines of Swift, CI green, and you can build it from source if you want to verify. The honest reason it's unsigned: Apple charges $99/year for notarization and Compass makes $0. Until sponsors fund it, your Mac will warn you once — right-click → Open, or use Homebrew. We'd rather be transparent than pretend.",
  },
  {
    q: "One maintainer — will this die like other projects?",
    a: "Compass is the editor I use every day to build itself. It's MIT — even if I vanished tomorrow, it's yours, forever. I'm not planning to vanish: the roadmap is public, the code is open, and the community decides what comes next.",
  },
  {
    q: "Why macOS-only?",
    a: "Deliberately. Going deep on Apple Silicon is how the app stays ~200MB with sub-100ms completion and Neural Engine acceleration. There are plenty of editors that work everywhere. There's one native AI IDE for macOS.",
  },
  {
    q: "What about native Anthropic/OpenAI support?",
    a: "On the public roadmap. Until it lands, OpenRouter gives you Claude and GPT through a single key — today.",
  },
  {
    q: "Local models are weak, aren't they?",
    a: "We never ask local to do cloud's job. Local handles what must be instant and private — completion, Q&A, search, chat. Cloud handles what needs frontier reasoning — agentic work with your key. Right tool for the job, always.",
  },
  {
    q: "Where are the benchmarks?",
    a: "Coming with v1.5, published in the open: latency p50/p95, RAM, index time. We publish numbers we measured, not numbers we hope for.",
  },
  {
    q: "I have years of muscle memory in Cursor.",
    a: "Keyboard is keyboard. Command palette, familiar editing, native macOS feel. Fifteen minutes and you're home — and your Mac gets a gigabyte of RAM back.",
  },
  {
    q: "Can my team use it?",
    a: "Yes. One brew line to onboard, your team's keys, usage-based cloud instead of per-seat. Zero egress by default tends to make security teams happy.",
  },
  {
    q: "How do I install it?",
    a: "Homebrew with the cask (ships with v0.7). Until then: DMG from GitHub Releases — right-click → Open the first time. That's the whole ritual.",
  },
] as const;
