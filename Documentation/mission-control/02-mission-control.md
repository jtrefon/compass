# 02 — Mission Control Block

> Part of: [Mission Control Spec](00-overview.md)

---

## 1. Purpose

Mission Control is a dynamic text block injected as the **last user message** before the model generates. It gives the model persistent access to its goal, plan, working memory, key code excerpts, and context budget — all in one compact, protected block that survives context resets and is never corrupted by token pressure.

---

## 2. Structure

Mission Control has five sections, rendered in a fixed order:

```
## MISSION CONTROL

### Goal
{plan.goal}
Value: {plan.value}

### Plan
{plan progress as checklist}
Progress: {completed}/{total} tasks complete

### Working Memory
{notes organized by section, clustered by NPU}

### Key Excerpts
{NPU-selected relevant code chunks from recent tool results}

### Context Budget
{tokens used} / {context length} tokens ({percent}% used)
{adaptive conservation guidance}
```

---

## 3. Section Details

### 3.1 Goal + Value

Sourced from the existing `TaskPlan`:

```swift
let goalSection = """
### Goal
\(plan?.goal ?? "No plan set — call plan(action: \"init\") to start planning.")
Value: \(plan?.value ?? "As requested by the user")
"""
```

**Example output:**
```
### Goal
Review WordPress plugin for security and code quality
Value: Identify vulnerabilities and code quality issues before deployment
```

If no plan exists, the model is prompted to create one. This ensures Mission Control always has a goal — the agent should never be working without knowing why.

### 3.2 Plan + Progress

Sourced from `TaskPlan.markdown` (existing property) with progress annotation:

```swift
let planSection = """
### Plan
\(plan?.markdown ?? "No plan items — call plan(action: \"finishTask\", summary: \"...\") to create tasks.")
Progress: \(plan?.progressString ?? "0/0") tasks complete
"""
```

**Example output:**
```
### Plan
# Implementation Plan

**Goal:** Review WordPress plugin for security
**Value:** Identify vulnerabilities before deployment
**Domain:** analysis

1. [x] Understand plugin architecture
2. [ ] Audit payment flow for security issues
3. [ ] Check input validation across all endpoints
4. [ ] Write final review report

Progress: 1/4 tasks complete
```

The checklist uses `[x]` for completed, `[ ]` for pending, `[!]` for blocked — matching the existing `TaskPlan.markdown` format.

### 3.3 Working Memory

Sourced from `WorkingMemoryStore`, rendered by `MissionControlBuilder`:

```swift
let memorySection = """
### Working Memory
\(workingMemory.renderForContext())
"""
```

**Rendering rules:**
- Notes are grouped by `section` name
- Sections are ordered by NPU clustering (semantically related sections adjacent)
- Each note is 1-3 lines (the model was instructed to keep notes compact)
- If no notes exist: `"No notes yet — call note() after reading files to build your working memory."`

**Example output:**
```
### Working Memory

**architecture:**
plugin-entry.php: 3 hooks (init, admin_menu, rest_api_init). Controller at L23. Delegates to PaymentService + NotificationService. REST base: /wp-json/plugin/v1/

**PaymentService:**
lib/PaymentService.php. Stripe+PayPal. processPayment() at L34. Webhook at /v1/webhook. NO input validation on amount (RISK). Hardcoded Stripe key in constructor (CRITICAL).

**NotificationService:**
lib/NotificationService.php. wp_mail + Twilio SMS. sendEmail() L12, sendSMS() L45. Twilio key from env var (good). No rate limiting on SMS (RISK).

**risks:**
- Hardcoded Stripe key (CRITICAL) — PaymentService constructor
- No amount validation (RISK) — processPayment L34
- No SMS rate limiting (RISK) — NotificationService sendSMS L45
```

See [03-note-tool.md](03-note-tool.md) for the `WorkingMemoryStore` spec and [04-npu-semantic-layer.md](04-npu-semantic-layer.md) for clustering.

### 3.4 Key Excerpts

Sourced from `SemanticCompressor` — the NPU-selected most relevant code chunks from recent tool results:

```swift
let excerptsSection = """
### Key Excerpts
\(keyExcerpts.map { excerpt in
    "[\(excerpt.filePath):\(excerpt.lineRange)] \(excerpt.text)"
}.joined(separator: "\n"))
"""
```

**Rendering rules:**
- Top 3-5 excerpts by relevance score to current task
- Each excerpt includes file path and line range for surgical re-reads
- Excerpts are actual code (not paraphrased) — preserves exact syntax
- If no excerpts: section omitted (don't show empty sections)

**Example output:**
```
### Key Excerpts
[lib/PaymentService.php:8-11] $this->stripeKey = "sk_live_XXXXX";
$this->paypalKey = getenv("PAYPAL_KEY");

[lib/PaymentService.php:13-16] public function processPayment($amount, $currency) {
    // No validation on $amount
    $this->chargeStripe($amount, $currency);
}

[lib/NotificationService.php:45-52] public function sendSMS($to, $message) {
    // No rate limiting
    $this->twilio->messages->create($to, ['body' => $message]);
}
```

### 3.5 Context Budget

Computed live by `MissionControlBuilder`:

```swift
let budgetSection = """
### Context Budget
\(usedTokens) / \(contextLength) tokens (\(percentUsed)% used)
\(conservationGuidance)
"""
```

**Conservation guidance is adaptive based on usage:**

| Usage | Guidance |
|---|---|
| < 25% | `"Context is healthy. Explore freely, but take notes as you go."` |
| 25-50% | `"Context is filling up. Be surgical with reads (limit=20-30). Take notes after every read."` |
| 50-75% | `"Context is getting tight. Prioritize acting on your notes over new exploration."` |
| > 75% | `"⚠️ Context nearly full. Your notes have what you need — stop exploring and start acting."` |

**Dynamic context length:** The context length is read from the inference configuration (local) or `ModelContextRegistry` (cloud). No hardcoded numbers. On a 262K machine, the model sees `5000 / 262000 tokens (2% used)` and knows it has plenty of room. On a 30K machine, it sees `22000 / 30000 tokens (73% used)` and knows to conserve.

---

## 4. MissionControlBuilder

```swift
/// Builds the Mission Control block for injection as the last user message.
/// Runs on @MainActor (matches the tool loop's isolation).
@MainActor
final class MissionControlBuilder {
    private let workingMemoryStore: WorkingMemoryStore
    private let semanticCompressor: SemanticCompressor
    private let planStore: ConversationPlanStore
    
    struct BudgetInfo {
        let usedTokens: Int
        let contextLength: Int
        var percentUsed: Int { (usedTokens * 100) / max(1, contextLength) }
        var remainingTokens: Int { max(0, contextLength - usedTokens) }
    }
    
    /// Build the complete Mission Control block.
    func build(
        conversationId: String,
        contextLength: Int,
        usedTokens: Int
    ) async -> String {
        let plan = await planStore.getPlan(conversationId: conversationId)
        let workingMemory = await workingMemoryStore.get(conversationId: conversationId)
        let keyExcerpts = await semanticCompressor.currentKeyExcerpts(
            conversationId: conversationId
        )
        let budget = BudgetInfo(usedTokens: usedTokens, contextLength: contextLength)
        
        return render(
            plan: plan,
            workingMemory: workingMemory,
            keyExcerpts: keyExcerpts,
            budget: budget
        )
    }
    
    /// Compute the current context budget without building the full block.
    /// Used by the eviction/reset logic to check if a reset is needed.
    func computeBudget(
        messages: [ChatMessage],
        contextLength: Int,
        approximateTokenCount: (String) -> Int
    ) -> BudgetInfo {
        var usedTokens = 0
        for message in messages {
            let content = message.role == .tool
                ? ToolExecutionEnvelope.decode(from: message.content)?.payload ?? message.content
                : message.content
            usedTokens += approximateTokenCount(content) + 16
        }
        return BudgetInfo(usedTokens: usedTokens, contextLength: contextLength)
    }
    
    private func render(
        plan: TaskPlan?,
        workingMemory: WorkingMemorySnapshot,
        keyExcerpts: [KeyExcerpt],
        budget: BudgetInfo
    ) -> String {
        var sections: [String] = ["## MISSION CONTROL"]
        
        // Goal
        sections.append("""
        ### Goal
        \(plan?.goal ?? "No plan set — call plan(action: \"init\") to start planning.")
        Value: \(plan?.value ?? "As requested by the user")
        """)
        
        // Plan
        sections.append("""
        ### Plan
        \(plan?.markdown ?? "No plan items yet.")
        Progress: \(plan?.progressString ?? "0/0") tasks complete
        """)
        
        // Working Memory
        if !workingMemory.notes.isEmpty {
            sections.append("### Working Memory\n\(workingMemory.renderForContext())")
        } else {
            sections.append("### Working Memory\nNo notes yet — call note() after reading files to build your working memory.")
        }
        
        // Key Excerpts
        if !keyExcerpts.isEmpty {
            let excerptLines = keyExcerpts.prefix(5).map { e in
                "[\(e.filePath):\(e.lineRange)] \(e.text)"
            }
            sections.append("### Key Excerpts\n\(excerptLines.joined(separator: "\n"))")
        }
        
        // Context Budget
        sections.append("""
        ### Context Budget
        \(budget.usedTokens) / \(budget.contextLength) tokens (\(budget.percentUsed)% used)
        \(conservationGuidance(for: budget))
        """)
        
        return sections.joined(separator: "\n\n")
    }
    
    private func conservationGuidance(for budget: BudgetInfo) -> String {
        switch budget.percentUsed {
        case ..<25: return "Context is healthy. Explore freely, but take notes as you go."
        case 25..<50: return "Context is filling up. Be surgical with reads (limit=20-30). Take notes after every read."
        case 50..<75: return "Context is getting tight. Prioritize acting on your notes over new exploration."
        default: return "⚠️ Context nearly full. Your notes have what you need — stop exploring and start acting."
        }
    }
}
```

---

## 5. Injection Point

Mission Control is injected as the **last user message** before each model call. It is NOT part of the system prompt.

### Local path (`LocalModelToolLoop`)

```swift
// In LocalModelToolLoop.execute(), at the top of the repeat loop:
// (after history.clearStreamingBuffer, before sendMessageWithRetry)

let budget = missionControlBuilder.computeBudget(
    messages: history.requestMessages,
    contextLength: configuration.contextLength,
    approximateTokenCount: { [self] in approximateTokenCount($0) }
)

let missionControl = await missionControlBuilder.build(
    conversationId: configuration.conversationId,
    contextLength: configuration.contextLength,
    usedTokens: budget.usedTokens
)

// Append as last user message — does NOT invalidate prior KV cache
await history.append(ChatMessage(role: .user, content: missionControl))

// Now send to model
let response = try await aiInteractionCoordinator.sendMessageWithRetry(...)
```

**Important:** Mission Control is appended EVERY turn. This means each turn has a fresh Mission Control with updated notes, excerpts, and budget. The previous turn's Mission Control message remains in history (it's append-only), but the new one is the last message the model sees.

**Token cost:** Mission Control is ~1-3K tokens. On a 30K context, this is 3-10% of the budget. The value (persistent goal, plan, notes, excerpts, budget awareness) far exceeds the cost.

**Stale Mission Control messages in history:** Previous turns' Mission Control messages remain in history. This is acceptable because:
1. They are small (~1-3K each)
2. They show the progression of the agent's understanding (useful context)
3. During controlled reset, they are evicted along with other old messages
4. The NPU can compress them if needed (they're semantically redundant with the latest one)

### Cloud path (`AgentLoop`)

```swift
// In AgentLoop.llmCall(), before sending:
let budget = missionControlBuilder.computeBudget(
    messages: messages ?? historyCoordinator.requestMessages,
    contextLength: PipelineProcessor.requestTokenBudget(modelID: modelID),
    approximateTokenCount: { $0.count / 4 }
)

let missionControl = await missionControlBuilder.build(
    conversationId: request.conversationId,
    contextLength: budget.contextLength,
    usedTokens: budget.usedTokens
)

var finalMessages = messages ?? historyCoordinator.requestMessages
finalMessages.append(ChatMessage(role: .user, content: missionControl))

return try await aiCoordinator.sendMessageWithRetry(
    .init(messages: finalMessages, tools: tools, ...)
).get()
```

On the cloud path, Mission Control is appended to the request-time message list (not committed to history). This avoids polluting the permanent history with repeated Mission Control blocks. The cloud path rebuilds every request anyway.

---

## 6. Mission Control vs Existing Context Injection

| Existing mechanism | Mission Control | Relationship |
|---|---|---|
| `TaskPlan` (plan store) | Goal + Plan sections | Mission Control renders TaskPlan data — no duplication |
| `ContextTool` (RAG) | Key Excerpts section | Different: ContextTool retrieves from FAISS on demand; Key Excerpts are proactively selected by NPU |
| `ProjectShapeSummary` | Not included | Project shape stays in system prompt (static, KV-cached) |
| `RepoMap` | Not included | Repo map stays in system prompt (static, KV-cached) |
| `LocalModelIterationGuide` | Replaces guidance injection | Mission Control's budget guidance replaces the guide's corrective messages |

Mission Control does NOT replace the plan tool or the context tool. It **surfaces** their data in a protected, always-visible block. The plan tool still writes to `ConversationPlanStore`. The context tool still retrieves from FAISS. Mission Control reads from both and renders them together.

---

## 7. Size Budget

Mission Control should be kept under 3K tokens to avoid consuming too much of the working context. The builder enforces this:

| Section | Target size | Enforcement |
|---|---|---|
| Goal + Value | ~100 tokens | Truncate value to 200 chars |
| Plan + Progress | ~300 tokens | Limit to 20 plan items; truncate item descriptions to 200 chars |
| Working Memory | ~1,500 tokens | Limit to 15 notes; truncate each note to 300 chars; oldest notes evicted if over limit |
| Key Excerpts | ~800 tokens | Top 5 excerpts; each excerpt max 200 chars |
| Context Budget | ~100 tokens | Fixed format |
| **Total** | **~2,800 tokens** | **Enforced by builder** |

If working memory exceeds 15 notes, the oldest notes (by timestamp) are evicted from Mission Control rendering. They remain in `WorkingMemoryStore` and FAISS (retrievable via `context()` tool), just not rendered in the compact Mission Control block.
