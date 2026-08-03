# Deep Analysis: Language-Graph Branch Integration

## Executive Summary

This is a **deep analysis** of the conflicts between:
1. **Main branch**: OpenRouter with simpler tool execution (works)
2. **Language-graph branch**: MLX with RAG + LangGraph orchestration (broken)

The goal is to merge the advanced features (RAG, orchestration graph, enhanced reasoning) to work with OpenRouter **without** breaking the existing working flow.

---

## Critical Difference Analysis

### 1. Model Capability Gap

| Aspect | OpenRouter (Works) | MLX (Broken) |
|--------|-------------------|--------------|
| **Model Size** | Large (70B+) | Small (4B) |
| **Tool Calling** | Structured JSON | Requires recovery from text |
| **Context Window** | 128K+ tokens | 4K-8K tokens |
| **Reasoning** | 6-section structured | Can't maintain structure |
| **Orchestration** | Handles multi-turn | Gets confused → loops |

### 2. Root Cause of Dead Loop

The MLX model (Qwen3-4B-Instruct) fails in the [`ToolLoopHandler`](compass/Services/ConversationFlow/ToolLoopHandler.swift:76) because:

1. **Line 154-162**: Model emits "textual tool call pattern" but no structured calls
2. **Lines 191-300**: Recovery mechanism tries to parse JSON from text
3. **Recovery fails**: Model keeps outputting "tool_call" text without actual calls
4. **Stall detection triggers**: But correction prompts also fail with small model
5. **Loop continues**: Until `maxAgentIterations = 12` exhausts

### 3. What Works in OpenRouter Path

```
User Message → OpenRouterAIService → Tool Loop → Final Response
                ↓
          [Larger model handles orchestration properly]
```

### 4. What Breaks in MLX Path

```
User Message → LocalModelProcessAIService → Tool Loop → STUCK IN LOOP
                ↓
          [Small model can't handle orchestration]
```

---

## Features to Merge

### Features That SHOULD Be Enabled for OpenRouter

| Feature | Current State | Target State |
|---------|--------------|--------------|
| **RAG (Codebase Index)** | Works in both | Keep for both |
| **Orchestration Graph** | MLX broken | Enable for OpenRouter only |
| **Enhanced Reasoning** | MLX broken | Enable for OpenRouter only |
| **Strategic/Tactical Planning** | MLX broken | Enable for OpenRouter only |
| **Delivery Gate** | MLX broken | Enable for OpenRouter only |
| **Plan Tracking** | MLX broken | Enable for OpenRouter only |

### Features That Should Stay Disabled for MLX

| Feature | Current State | Target State |
|---------|--------------|--------------|
| **Agent Mode** | Broken | Force Chat mode |
| **Full Tool Loop** | Loops | Disable |
| **Complex Reasoning** | Fails | Simplify prompts |

---

## Surgical Integration Plan

### Phase 1: Create Model Capability Interface

**New File**: `compass/Services/ModelCapability.swift`

```swift
protocol ModelCapability {
    var supportsAdvancedOrchestration: Bool { get }
    var supportsComplexReasoning: Bool { get }
    var maxContextTokens: Int { get }
    var recommendedMaxIterations: Int { get }
}

struct OpenRouterCapability: ModelCapability {
    let supportsAdvancedOrchestration = true
    let supportsComplexReasoning = true
    let maxContextTokens = 128_000
    let recommendedMaxIterations = 12
}

struct MLXCapability: ModelCapability {
    let supportsAdvancedOrchestration = false
    let supportsComplexReasoning = false
    let maxContextTokens = 4096
    let recommendedMaxIterations = 3  // Much lower to prevent loops
}
```

### Phase 2: Modify ModelRoutingAIService

**File**: `compass/Services/ModelRoutingAIService.swift`

Add capability-aware routing:

```swift
actor ModelRoutingAIService: AIService {
    private let openRouterService: AIService
    private let localService: AIService
    private let selectionStore: LocalModelSelectionStore
    
    // NEW: Get capability based on which service will be used
    private func getCapability(for request: AIServiceMessageWithProjectRootRequest) async -> ModelCapability {
        if await selectionStore.isOfflineModeEnabled() {
            return MLXCapability()
        }
        if await shouldUseLocalModel(tools: request.tools) {
            return MLXCapability()
        }
        return OpenRouterCapability()
    }
    
    func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse {
        let capability = await getCapability(for: request)
        
        // CRITICAL: If MLX + Agent mode requested, force Chat mode
        if !capability.supportsAdvancedOrchestration && request.mode == .agent {
            let adjustedRequest = adjustRequestForCapability(request, capability)
            return try await localService.sendMessage(adjustedRequest)
        }
        
        // Normal routing
        if await selectionStore.isOfflineModeEnabled() {
            return try await localService.sendMessage(request)
        }
        // ... rest of routing
    }
    
    private func adjustRequestForCapability(
        _ request: AIServiceMessageWithProjectRootRequest,
        _ capability: ModelCapability
    ) -> AIServiceMessageWithProjectRootRequest {
        // Force Chat mode, reduce tools to read-only, simplify prompts
        return AIServiceMessageWithProjectRootRequest(
            messages: request.messages,
            explicitContext: request.explicitContext,
            tools: request.tools?.filter { $0.name.hasPrefix("index_") }, // Only RAG tools
            mode: .chat,  // Force chat mode
            projectRoot: request.projectRoot
        )
    }
}
```

### Phase 3: Simplify MLX System Prompts

**File**: `compass/Services/LocalModels/LocalModelProcessAIService.swift`

When in fallback mode (MLX), use simpler prompts:

```swift
private func buildSystemContent(tools: [AITool]?, mode: AIMode?, stage: AIRequestStage? = nil) -> String {
    var parts: [String] = []
    
    // SIMPLIFIED: No complex reasoning for small model
    if mode == .agent {
        // Instead of 6-section reasoning, use simple format
        parts.append("""
        When responding, you may include a brief reasoning in <reasoning>...</reasoning> tags.
        Keep it short - 2-3 sentences maximum.
        After reasoning, provide your answer directly.
        """)
    }
    
    // ... rest unchanged
}
```

### Phase 4: Adjust Tool Loop Constants for MLX

**File**: `compass/Services/ConversationFlow/ToolLoopConstants.swift`

```swift
enum ToolLoopConstants {
    // Keep for OpenRouter
    static let maxAgentIterations = 12
    
    // NEW: Reduced for MLX
    static let maxMLXAgentIterations = 3
    
    // Use capability to determine limit
    static func maxIterations(for capability: ModelCapability) -> Int {
        if capability.supportsAdvancedOrchestration {
            return maxAgentIterations
        }
        return maxMLXAgentIterations
    }
}
```

### Phase 5: Pass Capability Through Orchestration

**File**: `compass/Services/Orchestration/Graph/OrchestrationState.swift`

Add capability to state:

```swift
struct OrchestrationState: Sendable {
    // ... existing fields
    let modelCapability: ModelCapability?  // NEW
    
    // Pass through in request
    var request: SendRequest
    var response: AIServiceResponse?
    var lastToolResults: [ChatMessage] = []
    var transition: Transition
}
```

**File**: `compass/Services/ConversationSendCoordinator.swift`

```swift
private func executeConversationFlow(_ request: SendRequest) async throws -> AIServiceResponse {
    // Get capability for this request
    let capability = await getModelCapability(for: request)
    
    let graph = ConversationFlowGraphFactory.makeGraph(
        historyCoordinator: historyCoordinator,
        aiInteractionCoordinator: aiInteractionCoordinator,
        // ... other params
        modelCapability: capability  // NEW
    )
    
    let runner = OrchestrationGraphRunner(graph: graph)
    // Pass capability to determine max iterations
    let finalState = try await runner.run(initialState: OrchestrationState(
        request: request,
        transition: .next(graph.entryNodeId),
        modelCapability: capability  // NEW
    ))
    
    // ... rest
}
```

**File**: `compass/Services/Orchestration/Graph/OrchestrationGraphRunner.swift`

```swift
func run(initialState: OrchestrationState) async throws -> OrchestrationState {
    // Use capability to determine max transitions
    let maxTransitions: Int
    if let capability = initialState.modelCapability, 
       !capability.supportsAdvancedOrchestration {
        maxTransitions = 8  // Much lower for MLX
    } else {
        maxTransitions = 64  // Keep for OpenRouter
    }
    
    // ... rest of loop
}
```

---

## Files That MUST NOT Be Changed

These files work fine and should be left alone:

| File | Reason |
|------|--------|
| `compass/Services/OpenRouterAIService.swift` | Works perfectly |
| `compass/Services/OpenRouterAI/OpenRouterAIService+ChatPreparation.swift` | Works perfectly |
| `compass/Services/DependencyContainer.swift` | DI setup is fine |
| `compass/Services/ConversationToolProvider.swift` | Tools work for both |
| `compass/Services/Index/CodebaseIndex.swift` | RAG works for both |

---

## Files That Need Careful Modification

| File | Change Type | Risk Level |
|------|-------------|------------|
| `ModelRoutingAIService.swift` | Add capability routing | Medium |
| `LocalModelProcessAIService.swift` | Simplify prompts | Medium |
| `ToolLoopConstants.swift` | Add MLX constants | Low |
| `OrchestrationState.swift` | Add capability field | Low |
| `ConversationSendCoordinator.swift` | Pass capability | Medium |
| `OrchestrationGraphRunner.swift` | Use capability for limits | Low |

---

## Verification Steps

After implementation, verify:

1. **OpenRouter + Agent Mode**: Full orchestration, 12 iterations, complex reasoning
2. **OpenRouter + Chat Mode**: Simple flow, read-only tools
3. **MLX + Agent Mode**: Should force Chat mode, reduced iterations, simple reasoning
4. **MLX + Chat Mode**: RAG works, read-only tools, no loops

---

## Migration Path

### Step 1: Create ModelCapability protocol (New file)
- No risk, additive change

### Step 2: Modify ModelRoutingAIService
- Add capability detection
- Add request adjustment for MLX + Agent
- **Risk**: Could break routing if done incorrectly
- **Mitigation**: Test each routing path

### Phase 3: Test in isolation
- Test OpenRouter paths first
- Then test MLX paths
- Verify no regressions

---

## Summary

This plan provides:

1. **Zero breaking changes** to working OpenRouter flow
2. **Disabled orchestration** for MLX (prevents loops)
3. **Full feature enablement** for OpenRouter
4. **RAG support** for both (already works)
5. **Surgical changes** only where needed

The key insight is that the orchestration graph and complex reasoning are **model-dependent features** that should only be enabled for capable models (OpenRouter), not forced onto small local models (MLX) that can't handle them.
