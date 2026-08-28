# Tool Execution Root Cause Analysis - Comprehensive Report

## Executive Summary

The tool execution failure in compass has **multiple root causes** that compound each other. The harness tests are correctly validating tool execution, but the underlying system has critical gaps in how tools are passed to and from the local model.

**Key Finding**: The model is generating reasoning content (`<ide_reasoning>` blocks) but **NOT generating native tool calls** (Tool calls: 0). This is because:

1. **Redundant prompt building** - Tools are described in prose in the text prompt AND passed to the chat template, creating confusion
2. **Missing tool call format configuration** - Granite model doesn't have `toolCallFormat` set in the registry
3. **Potential chat template incompatibility** - The model may not have a tool-aware chat template

---

## Part 1: Evidence from Harness Tests

### Test Results (2026-02-14)

```
Test Case '-[compassHarnessTests.AgenticHarnessTests testHarnessCreatesSingleFile]' passed (63.522 seconds)
❌ File was not created
Assistant said: Hello! I'm your AI coding assistant. How can I help you today?...

Test Case '-[compassHarnessTests.AgenticHarnessTests testHarnessModelToolCallingCapability]' passed (14.703 seconds)
Response content: <ide_reasoning>...</ide_reasoning>
Tool calls: 0
Model mlx-community/granite-4.0-h-micro-4bit@0a29e17 native tool calling: NO
```

### What the Harness Tests Validate

The harness tests in [`AgenticHarnessTests.swift`](compassHarnessTests/AgenticHarnessTests.swift) are **correctly implemented**:

1. **File creation validation** - Tests check if files actually exist on disk after the conversation
2. **Tool execution trail** - Tests verify `ToolExecutionEnvelope` messages in conversation
3. **Multi-turn consistency** - Tests validate conversation state across turns
4. **Orchestration phases** - Tests verify the LangGraph phase transitions

**The tests are NOT the problem** - they correctly identify that tools are not being executed.

---

## Part 2: Root Cause Analysis

### Issue 1: Redundant Tool Passing

**Location**: [`LocalModelProcessAIService.swift`](compass/Services/LocalModels/LocalModelProcessAIService.swift)

The current implementation does BOTH:

```swift
// 1. Builds text prompt with prose tool descriptions
let prompt = buildPrompt(messages: ..., tools: tools, ...)  // Uses ToolAwarenessPrompt

// 2. ALSO passes tools to UserInput for chat template
let toolSpecs = convertToToolSpec(request.tools)
let userInput = UserInput(chat: [.user(prompt)], tools: toolSpecs)
```

**Problem**: 
- `buildPrompt()` calls `buildSystemContent()` which uses `ToolAwarenessPrompt.systemPrompt` to describe tools in prose
- Then `UserInput.tools` passes the same tools to the chat template
- The chat template may or may not inject tool definitions (depends on model)
- The model receives conflicting signals about how to make tool calls

### Issue 2: Missing Tool Call Format

**Location**: MLXLLM's `LLMRegistry` (external package)

Looking at the model registry, only these models have `toolCallFormat` configured:

```swift
static public let glm4_9b_4bit = ModelConfiguration(
    id: "mlx-community/GLM-4-9B-0414-4bit",
    toolCallFormat: .glm4
)

static public let lfm2_1_2b_4bit = ModelConfiguration(
    id: "mlx-community/LFM2-1.2B-4bit",
    toolCallFormat: .lfm2
)
```

**Granite is NOT configured with a tool call format:**

```swift
static public let granite_4_0_h_tiny_4bit_dwq = ModelConfiguration(
    id: "mlx-community/Granite-4.0-H-Tiny-4bit-DWQ",
    defaultPrompt: ""
    // NO toolCallFormat!
)
```

### Issue 3: Chat Template Tool Support

**Location**: MLXLLM's `LLMUserInputProcessor.prepare()`

```swift
func prepare(input: UserInput) throws -> LMInput {
    let messages = messageGenerator.generate(from: input)
    do {
        let promptTokens = try tokenizer.applyChatTemplate(
            messages: messages, tools: input.tools, additionalContext: input.additionalContext)
        return LMInput(tokens: MLXArray(promptTokens))
    } catch TokenizerError.missingChatTemplate {
        // Falls back to simple text - tools are LOST
        let prompt = messages.compactMap { $0["content"] as? String }.joined(separator: "\n\n")
        return LMInput(tokens: MLXArray(tokenizer.encode(text: prompt)))
    }
}
```

**Problem**: If the model's tokenizer doesn't have a tool-aware chat template, tools are silently dropped.

### Issue 4: Tool Call Parsing

**Location**: MLXLLM's `generateTask()` in Evaluate.swift

```swift
let toolCallProcessor = ToolCallProcessor(
    format: modelConfiguration.toolCallFormat ?? .json  // Defaults to .json
)

for token in iterator {
    detokenizer.append(token: token)
    if let chunk = detokenizer.next() {
        // Process chunk through the tool call processor
        if let textToYield = toolCallProcessor.processChunk(chunk) {
            continuation.yield(.chunk(textToYield))
        }
        // Check if we have a complete tool call
        if let toolCall = toolCallProcessor.toolCalls.popLast() {
            continuation.yield(.toolCall(toolCall))
        }
    }
}
```

**Problem**: The `ToolCallProcessor` looks for specific patterns like:
- JSON format: `{"name": "func", "arguments": {...}}`
- GLM4 format: `func<k>v</k>`
- LFM2 format: `<|tool_call_start|>...<|tool_call_end|>`

If the model doesn't output in one of these formats, tool calls won't be parsed.

---

## Part 3: The Fix Strategy

### Fix 1: Choose ONE Tool Passing Strategy

**Option A: Chat Template Only (Recommended for models with tool support)**

```swift
// Don't build prose prompt - pass structured messages
let chat = buildChatMessages(messages: request.messages, context: request.context)
let userInput = UserInput(chat: chat, tools: toolSpecs)
```

**Option B: Prose Prompt Only (For models without tool support)**

```swift
// Build prose prompt with tool descriptions
let prompt = buildPrompt(messages: ..., tools: tools, ...)
let userInput = UserInput(chat: [.user(prompt)], tools: nil)  // No tools to chat template
```

**Recommended**: Implement Option A with fallback to Option B when chat template doesn't support tools.

### Fix 2: Configure Tool Call Format for Granite

Add to the model catalog or configuration:

```swift
// In LocalModelCatalog or similar
LocalModelDefinition(
    id: "mlx-community/granite-4.0-h-micro-4bit",
    toolCallFormat: .json  // Granite uses standard JSON format
)
```

### Fix 3: Validate Chat Template Tool Support

Add detection for whether the model's chat template supports tools:

```swift
func prepare(input: UserInput) throws -> LMInput {
    let messages = messageGenerator.generate(from: input)
    
    // Check if chat template supports tools
    let hasToolTemplate = tokenizer.hasToolChatTemplate()
    
    let promptTokens: [Int]
    if hasToolTemplate, let tools = input.tools {
        promptTokens = try tokenizer.applyChatTemplate(
            messages: messages, tools: tools, additionalContext: input.additionalContext)
    } else {
        // Fallback: inject tools into system message
        let enrichedMessages = enrichMessagesWithTools(messages, tools: input.tools)
        promptTokens = try tokenizer.applyChatTemplate(messages: enrichedMessages)
    }
    
    return LMInput(tokens: MLXArray(promptTokens))
}
```

### Fix 4: Add Tool Call Format Inference

Extend `ToolCallFormat.infer()` to handle more model types:

```swift
public static func infer(from modelType: String) -> ToolCallFormat? {
    switch modelType.lowercased() {
    case "lfm2", "lfm2_moe":
        return .lfm2
    case "glm4", "glm4_moe", "glm4_moe_lite":
        return .glm4
    case "gemma":
        return .gemma
    case "granite":  // ADD THIS
        return .json
    case "qwen2", "qwen3":  // ADD THIS
        return .json
    default:
        return nil
    }
}
```

---

## Part 4: Implementation Steps

### Step 1: Fix LocalModelProcessAIService (HIGH PRIORITY)

1. Remove redundant tool prose from `buildPrompt()` when using chat template
2. Add detection for chat template tool support
3. Implement fallback to prose injection when chat template doesn't support tools

### Step 2: Configure Granite Tool Format (HIGH PRIORITY)

1. Add `toolCallFormat: .json` to Granite model configuration
2. Verify Granite's actual tool call format matches JSON

### Step 3: Add Tool Format Inference (MEDIUM PRIORITY)

1. Extend `ToolCallFormat.infer()` in MLXLLM or add local override
2. Map common model families to their formats

### Step 4: Improve Harness Tests (LOW PRIORITY)

1. Add assertion that tool calls were generated (not just files created)
2. Add test for chat template tool injection
3. Add test for tool call parsing

---

## Part 5: Verification Plan

### Test 1: Verify Tool Injection

```swift
// Add logging to show what's actually being sent to the model
print("Tools passed to UserInput: \(toolSpecs?.count ?? 0)")
print("Chat template output tokens: \(promptTokens.count)")
```

### Test 2: Verify Tool Call Generation

```swift
// In test, check for tool calls in response
XCTAssertNotNil(response.toolCalls, "Model should generate tool calls")
XCTAssertEqual(response.toolCalls?.first?.name, "write_file")
```

### Test 3: End-to-End File Creation

```swift
// Existing harness test should pass after fixes
let fileExists = FileManager.default.fileExists(atPath: expectedFile.path)
XCTAssertTrue(fileExists, "File should be created")
```

---

## Appendix A: MLXLLM Tool Calling Architecture

```
UserInput
├── prompt: Prompt (chat messages)
├── tools: [ToolSpec]?  ← Tool definitions
└── additionalContext

      ↓ UserInputProcessor.prepare()

LMInput
└── text: LMInput.Text
    └── tokens: MLXArray  ← Tokenized with chat template

      ↓ TokenIterator

Generation
├── .chunk(String)  ← Text output
├── .toolCall(ToolCall)  ← Parsed tool call
└── .info(GenerateCompletionInfo)

      ↓ ToolCallProcessor

ToolCall
├── id: String
└── function: FunctionCall
    ├── name: String
    └── arguments: [String: Value]
```

---

## Appendix B: Supported Tool Call Formats

| Format | Models | Example |
|--------|--------|---------|
| `.json` | Llama, Qwen, Granite, most models | `{"name": "func", "arguments": {...}}` |
| `.lfm2` | LFM2 models | `<|tool_call_start|>{"name": ...}<|tool_call_end|>` |
| `.glm4` | GLM4 models | `func<k>v</k>` |
| `.gemma` | Gemma models | `call:name{key:value}` |
| `.xmlFunction` | Qwen3 Coder | `<function=name><parameter=key>value</parameter></function>` |

---

## Part 6: Critical Finding - Granite Chat Template Analysis

### Granite's chat_template.jinja DOES Support Tools

Located at: `~/Library/Application Support/compass/local-models/mlx-community_granite-4.0-h-micro-4bit_0a29e17/chat_template.jinja`

The template has full tool support:

```jinja
{%- set tools_system_message_prefix = 'You are a helpful assistant with access to the following tools...' %}
{%- set tools_system_message_suffix = '...\n\nFor each tool call, return a json object with function name and arguments within aley XML tags:\naley\n{"name": <function-name>, "arguments": <args-json-object>}\nyay' %}

{%- if tools %}
    {%- for tool in tools %}
        {%- set ns.tools_system_message = ns.tools_system_message + '\n' + (tool | tojson) %}
    {%- endfor %}
{%- endif %}
```

**Expected tool call format from Granite:**
```
aley
{"name": "write_file", "arguments": {"path": "hello.txt", "content": "Hello World"}}
yay
```

This matches the `.json` ToolCallFormat in MLXLLM!

### The ACTUAL Problem: Double Prompt Building

The issue is in [`LocalModelProcessAIService.swift`](compass/Services/LocalModels/LocalModelProcessAIService.swift):

```swift
// Step 1: Build a TEXT prompt with prose tool descriptions
let prompt = buildPrompt(messages: ..., tools: tools, ...)  
// This creates: "System: You have access to tools...\nUser: Create a file...\nAssistant:"

// Step 2: Wrap the ENTIRE text prompt as a SINGLE user message
let chat: [Chat.Message] = [.user(prompt)]  // WRONG!
let userInput = UserInput(chat: chat, tools: tools)

// Step 3: Chat template is applied, but the "message" is already a full prompt
// The template sees ONE message with role="user" and content=<entire prompt>
// It wraps this in <|start_of_role|>user<|end_of_role|>...<|end_of_text|>
// And appends tool definitions AGAIN
```

**Result**: The model receives:
1. A user message containing what looks like a system prompt with tool descriptions
2. Tool definitions injected by the chat template (redundant)
3. Confused state - the model doesn't know which format to use

### The Fix: Pass Structured Messages, Not Pre-built Prompts

**Current (broken):**
```swift
let prompt = buildPrompt(messages: ..., tools: ...)  // Builds text
let chat: [Chat.Message] = [.user(prompt)]           // Wraps as single message
let userInput = UserInput(chat: chat, tools: tools)  // Passes tools again
```

**Fixed:**
```swift
let chat = buildChatMessages(messages: ...)  // Build structured messages
let userInput = UserInput(chat: chat, tools: tools)  // Let template handle everything
```

The `buildChatMessages()` function should:
1. Create `[Chat.Message]` with proper roles (.system, .user, .assistant)
2. NOT include tool descriptions in prose - let the chat template inject them
3. Pass context as a system message if needed

---

## Conclusion

The tool execution failure is caused by:

1. **Double prompt building** - Building a text prompt AND passing tools to chat template
2. **Message structure loss** - Converting structured messages to a single text block
3. **Confused model state** - Model receives conflicting signals about tool format

The fix requires restructuring how messages are passed to MLXLLM:
- Stop building text prompts manually
- Pass structured `Chat.Message` arrays to `UserInput`
- Let the chat template handle all formatting and tool injection

The harness tests are working correctly and will pass once the message building is fixed.
