import Foundation

/// Curated local-benchmark tasks with hand-written golden answers.
/// Golden answers drive the quality KPIs (semantic similarity + checklist
/// completeness); tool tasks drive the agentic-compliance KPIs.
struct LocalBenchTask {
    let id: String
    let prompt: String
    let golden: String
    let checklist: [String]
    /// When non-nil, the task instructs a JSON tool call and compliance KPIs
    /// apply (valid JSON, name/arguments schema, expected tool name).
    let expectsToolCall: Bool
    let expectedToolName: String?
    /// Optional context injected before the prompt (long-context recall).
    let context: String?

    init(
        id: String,
        prompt: String,
        golden: String,
        checklist: [String],
        expectsToolCall: Bool = false,
        expectedToolName: String? = nil,
        context: String? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.golden = golden
        self.checklist = checklist
        self.expectsToolCall = expectsToolCall
        self.expectedToolName = expectedToolName
        self.context = context
    }
}

enum LocalBenchFixtures {
    static let all: [LocalBenchTask] = [
        LocalBenchTask(
            id: "qa_swift_options",
            prompt: "In Swift, when would you use an enum with associated values instead of a struct? Answer in one short paragraph.",
            golden: "An enum with associated values models a fixed set of mutually exclusive cases, each carrying its own data — e.g. a Result.success(error) style state machine. A struct models a bundle of independent stored properties that always coexist. Enums win for exclusive states; structs win for plain data records.",
            checklist: ["enum", "associated", "struct", "mutually exclusive", "state"]
        ),
        LocalBenchTask(
            id: "qa_gcd_serial",
            prompt: "What does a serial DispatchQueue guarantee about task execution? Answer in one or two sentences.",
            golden: "A serial DispatchQueue executes its submitted blocks one at a time, in FIFO order — at most one block runs at any moment, so shared mutable state needs no locking as long as all access happens on that queue.",
            checklist: ["one at a time", "FIFO", "serial", "order", "block"]
        ),
        LocalBenchTask(
            id: "qa_http_status",
            prompt: "What does HTTP status 429 mean and what should a client do? One or two sentences.",
            golden: "429 Too Many Requests means the client hit a rate limit. The client should back off — ideally honoring the Retry-After header — and retry later with exponential backoff.",
            checklist: ["429", "rate limit", "Retry-After", "backoff", "retry"]
        ),
        LocalBenchTask(
            id: "tool_rename_file",
            prompt: """
            You have access to this tool:
            {"name": "rename_file", "description": "Rename a file", "parameters": {"type": "object", "properties": {"oldPath": {"type": "string"}, "newPath": {"type": "string"}}, "required": ["oldPath", "newPath"]}}

            The user wants to rename "src/a.txt" to "src/b.txt". Reply with a single tool call in this exact format, nothing else:
            <tool_call>{"name": "rename_file", "arguments": {"oldPath": "src/a.txt", "newPath": "src/b.txt"}}</tool_call>
            """,
            golden: "<tool_call>{\"name\": \"rename_file\", \"arguments\": {\"oldPath\": \"src/a.txt\", \"newPath\": \"src/b.txt\"}}</tool_call>",
            checklist: ["rename_file", "src/a.txt", "src/b.txt"],
            expectsToolCall: true,
            expectedToolName: "rename_file"
        ),
        LocalBenchTask(
            id: "tool_search_symbols",
            prompt: """
            You have access to this tool:
            {"name": "search_symbols", "description": "Find symbol definitions", "parameters": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}}

            Find the definition of "renderLoop". Reply with a single tool call in this exact format, nothing else:
            <tool_call>{"name": "search_symbols", "arguments": {"query": "renderLoop"}}</tool_call>
            """,
            golden: "<tool_call>{\"name\": \"search_symbols\", \"arguments\": {\"query\": \"renderLoop\"}}</tool_call>",
            checklist: ["search_symbols", "renderLoop"],
            expectsToolCall: true,
            expectedToolName: "search_symbols"
        ),
        LocalBenchTask(
            id: "ctx_compress_recall",
            prompt: "Given the context above, what file extension does the project use for test files, and what port does the dev server run on?",
            golden: "The project uses .test.js for test files and the dev server runs on port 5173.",
            checklist: [".test.js", "5173"],
            context: """
            Project overview: a Vite-based React application. Test files are named with the .test.js extension and live next to their components. The dev server binds to localhost on port 5173. The production build outputs to dist/ and is served over port 4173.
            """
        ),
    ]
}
