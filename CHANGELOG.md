# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.0] - Unreleased

### Changed
- Full codebase rename: project (`Compass.xcodeproj`), targets, scheme, and source
  directories are now `Compass` (was `osx-ide`)

## [0.6.1] - 2026-08-01

### Changed
- Rebranded to **Compass** (product name, cask, release artifacts)
- Provider API keys now stored in the macOS Keychain (migrated from UserDefaults)
- Tool execution: real timeouts, write serialization, circuit breaker,
  ai-trace logging restored on the live path
- Index exclusions: hybrid predefined + dynamic (LLM-maintained) list

### Bug Fixes
- Assistant answers could silently never reach conversation history
- Review-path sends crashed with "missing node id=architect"
- Tool-call markup parsing was order-nondeterministic; HTML entities and
  MiniMax aliases not handled
- Absolute-path escape attempts were silently re-rooted instead of rejected
- Indexer duplicated symbol rows on every reindex; SQLite transient-bind
  use-after-free
- Local model: KV cache per conversation no longer unbounded; first streamed
  chunks were dropped; downloads could resume a continuation twice
- A locked paired iPhone no longer blocks `./run.sh test`
- Context display used the provider's real token window

## [0.6.0] - 2026-04-10

### Added
- ✨ Turbo Quant inference engine support
- ✨ Google Gemma 4 model integration
- ✨ Inline code completion
- 🚀 Improved code generation quality and performance

### Improvements
- Faster model loading times
- Reduced memory usage
- Better context window handling
- Improved error handling

### Bug Fixes
- Fixed model unload memory leak
- Fixed completion cancellation
- Fixed UI freeze during generation

## [0.5.0] - 2026-03-16

### Added
- Enhanced local MLX model support with benchmarking and preload capabilities
- Structured local embedding model management with catalog and downloader
- Production-parity local model tuning controls
- RAG enrichment and prevention implementation documentation
- UI status gauge and telemetry aggregation for RAG system
- Segment-level retrieval and stage-aware context budgeting
- Git LFS tracking for CoreML embedding models
- OpenRouter rate limiting and reindex confirmation dialog
- Multi-provider support with OpenRouter and Alibaba Cloud
- Power management integration for agent tool loops
- Biometric authentication requirement for keychain access
- Agent memory toggle and conversation flow improvements
- Reasoning UI enhancements with collapsible toggles and progress tracking
- Tool execution timeout with countdown UI and enhanced error recovery
- OpenRouter context usage display in status bar
- LocalModelProcessAIService enhancements with new tool prompt modes
- MLX Swift dependencies for local model support
- Agentic architecture with multi-phase execution framework and RAG subsystem
- QA review toggle in agent settings
- Extended ANSI terminal rendering with color codes and scroll region handling
- Structured local embedding model management with catalog and downloader
- Git LFS tracking for CoreML embedding models
- OpenRouter rate limiting and reindex confirmation dialog
- Multi-provider support with OpenRouter and Alibaba Cloud
- Power management integration for agent tool loops
- Biometric authentication requirement for keychain access
- Agent memory toggle and conversation flow improvements
- Reasoning UI enhancements with collapsible toggles and progress tracking
- Tool execution timeout with countdown UI and enhanced error recovery
- OpenRouter context usage display in status bar
- LocalModelProcessAIService enhancements with new tool prompt modes
- MLX Swift dependencies for local model support
- Agentic architecture with multi-phase execution framework and RAG subsystem
- QA review toggle in agent settings
- Extended ANSI terminal rendering with color codes and scroll region handling

### Changed
- Refactored agent orchestration flow with DispatcherNode and planning tools
- Optimized file tree rendering for visible rows only (fixed UI dead loop)
- Deferred heavy service initialization to background threads
- Refined tool loop continuation logic with workspace directory change events
- Adjusted default UI panel widths for better layout balance
- Standardized app runtime environment and refactored UI tests
- Improved token budget management for reasoning (tightened to 60 tokens)
- Made reasoning optional across conversation flows
- Standardized reasoning format to Reflection/Planning/Continuity schema
- Enhanced chat mode restrictions and tool timeout handling
- Improved plan completion logic
- Refactored quality improvements: AIToolExecutor concurrency safety
- CodeFormatter strategy extraction
- File watcher implementation
- Session management fixes
- Multiple conversation directory prevention
- Execution logging restructuring to use conversation-based folders
- Language indicator implementation in status bar
- Terminal output processing refactoring
- CorePlugin command registration refactoring
- DatabaseManager schema methods simplification
- ChatMessage initializer parameter count reduction
- Terminal output loop complexity reduction
- Terminal ANSI rendering helpers split
- Database and logging improvements with prepared statement handling
- Overlay views and syntax highlighting refactoring
- Parameter passing consolidation with configuration structs
- View initialization complexity reduction
- Test formatting standardization
- Parameter passing with UpdateEditorContentRequest struct
- CorePlugin UI and command registration separation
- Appearance handling delegation to AppearanceCoordinator
- Parameter objects for long argument lists
- Cleanup of lints and temporary files

### Fixed
- Merge conflict in sonar-project.properties (combined exclusions from both branches)
- Various bug fixes and performance improvements in file browser and editor
- Fixed Codacy configuration and SonarQube issues
- Resolved terminal text wrapping and grid calculation issues
- Fixed legacy tool_code markup recovery
- Improved finalization and unfinished execution recovery
- Hardened orchestration execution recovery
- Fixed local MLX build path and added offline inference benchmarks
- Stabilized offline MLX benchmark and preload behavior
- Gated background indexing on inference activity
- Fixed Codacy config exclusions
- Added Codacy config to exclude Vendor and other non-project folders
- Improved SonarCloud config to explicitly exclude Vendor folder
- Fixed unit test compilation errors
- Fixed long line in AIMode.swift
- Fixed orchestration loops, tool path sandboxing, and UI window framing
- Enhanced Chat mode restrictions and plan completion logic
- Fixed openrouter tool call argument aggregation in streaming responses
- Fixed window/layout restore and stabilized UI regression tests
- Fixed gitignore to exclude build artifacts and debug files
- Fixed sandbox folder handling
- Fixed reasoning hide per message and enforced 4-stage reasoning
- Fixed multiple conversation directories created on app launch
- Fixed project conversation folder creation
- Simplified execution logging and UI button
- Restructured logging to use conversation-based folders
- Fixed reasoner validation to detect implementation details
- Updated reasoning implementation status in architecture docs
- Restored automatic window resizability
- Refactored conversation flow with stage-based tool filtering
- Sanitized assistant messages to strip reasoning from model input
- Replaced folded messages with summary instead of removal
- Enhanced window appearance by disabling transparency and movable background
- Introduced delivery validation helpers for work completion detection
- Refactored conversation flow: reordered QA review handlers
- Added run snapshot logging for quality review
- Enhanced delivery status validation logic
- Refactored conversation flow: extracted orchestration logic into handler classes
- Added type field to AIToolCall
- Removed test_reasoning.swift
- Replaced master/slave terminology with primary/secondary in ShellManager
- Fixed blinking cursor
- Fixed gap issues
- Added OS X specific rules
- Fixed tech debt - refactor
- Fixed go to definition
- Fixed feature list implementation
- Fixed indexing
- Fixed coloring
- Fixed chat issues
- Fixed failed tests
- Fixed font size issues
- Fixed reasoning hide per message
- Added reasoning panel + toggle
- Fixed agentinc functionality
- Implemented new project feature
- Fixed settings
- Fixed core indexer
- Fixed CI deployment target
- Enabled CI builds on all branches
- Fixed markdown processor
- Fixed core indexer: index-backed file discovery/search tools
- Fixed ai indexing
- Fixed echo removal and terminal issues
- Fixed double echo in console
- Fixed search crashing
- Fixed terminal glitch
- Fixed tree sitter removal instabilities and sigfaults
- Fixed arch refactor
- Fixed search
- Fixed OpenRouter AI settings and release notes
- Fixed icon
- Fixed trigger release workflow on tag push
- Fixed README badges and package DMG on release
- Fixed tests on hosted macOS runners
- Fixed Xcode version selection in workflows
- Fixed docs and CI/release workflows
- Fixed file tree native implementation
- Fixed various other issues

## [0.4.0] - 2026-01-09

### Added

- Enhanced codebase indexing with memory system and symbol extraction
- Multi-role AI agent orchestration (Architect, Planner, Worker, QA)
- Improved terminal panel with build error diagnostics
- Markdown rendering support for chat output
- Project session persistence for window layout and open tabs

### Changed

- Refactored code for better maintainability and reduced complexity
- Updated AI provider settings and command palette integration

### Fixed

- Various bug fixes and performance improvements in file browser and editor

## [0.2.0] - 2025-12-21

### Added

- Liquid-glass settings UI with tabbed General and AI sections.
- OpenRouter configuration (API key, model selection, autocomplete, latency test).
- System prompt editor to override default AI behavior.
- OpenRouter-backed AI service wired to chat.

### Changed

- Settings menu command now uses a single, iconized entry.
