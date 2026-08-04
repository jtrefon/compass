import Foundation

public enum LocalModelFileStore {
    enum LocalModelFileStoreError: Error, LocalizedError {
        case missingRequiredRuntimeArtifact(modelId: String, fileName: String)

        var errorDescription: String? {
            switch self {
            case let .missingRequiredRuntimeArtifact(modelId, fileName):
                return "Required runtime artifact \(fileName) is missing for model \(modelId)."
            }
        }
    }
    struct ModelConfig: Codable {
        let maxPositionEmbeddings: Int?
        let maxSequenceLength: Int?
        let modelType: String?
        let textConfig: TextConfig?

        struct TextConfig: Codable {
            let maxPositionEmbeddings: Int?
            let maxSequenceLength: Int?
            let modelType: String?

            enum CodingKeys: String, CodingKey {
                case maxPositionEmbeddings = "max_position_embeddings"
                case maxSequenceLength = "max_sequence_length"
                case modelType = "model_type"
            }
        }

        enum CodingKeys: String, CodingKey {
            case maxPositionEmbeddings = "max_position_embeddings"
            case maxSequenceLength = "max_sequence_length"
            case modelType = "model_type"
            case textConfig = "text_config"
        }

        var contextLength: Int? {
            maxPositionEmbeddings
                ?? maxSequenceLength
                ?? textConfig?.maxPositionEmbeddings
                ?? textConfig?.maxSequenceLength
        }

        var effectiveModelType: String? {
            modelType ?? textConfig?.modelType
        }
    }

    /// Test isolation: unit tests MUST never read, migrate, or delete the
    /// user's real downloaded models. When set (by tests only), every model
    /// path — canonical root AND legacy migration candidates — is resolved
    /// under this directory instead of Application Support / Caches.
    /// Production code never sets this; it stays `nil` in normal runs.
    /// `nonisolated(unsafe)`: written once in test setUp, read on the main
    /// actor during tests; never touched by production.
    #if DEBUG
    nonisolated(unsafe) static var testRootOverride: URL?
    #endif

    public static func modelsRootDirectory() throws -> URL {
        #if DEBUG
        if let override = testRootOverride {
            try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        #endif

        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let root =
            appSupport
            .appendingPathComponent("Compass", isDirectory: true)
            .appendingPathComponent("local-models", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func modelDirectory(modelId: String) throws -> URL {
        let sanitized = sanitizeModelId(modelId)
        return try modelsRootDirectory().appendingPathComponent(sanitized, isDirectory: true)
    }

    static func artifactURL(modelId: String, fileName: String) throws -> URL {
        try modelDirectory(modelId: modelId).appendingPathComponent(fileName, isDirectory: false)
    }

    /// Runtime directory for the fixed chat model (Qwen3.5-4B): the original
    /// chat_template.jinja has a multi_step_tool validation that raises
    /// "No user query found in messages" when tool results are sent back
    /// without a trailing user query. Our custom template handles this
    /// correctly by wrapping tool results as user messages with Tool Output
    /// prefix — always applied, no per-model branching.
    static func chatRuntimeModelDirectory() throws -> URL {
        let model = LocalModelCatalog.chatModel
        let installedDirectory = try ensureCanonicalInstallation(for: model)
        return try prepareRuntimeCompatibilityDirectory(
            sourceDirectory: installedDirectory,
            model: model
        )
    }

    /// Runtime directory for the fixed FIM model (Qwen2.5-Coder-1.5B):
    /// the installed directory is used as-is.
    static func fimModelDirectory() throws -> URL {
        let model = LocalModelCatalog.fimModel
        return try ensureCanonicalInstallation(for: model)
    }

    static func isModelInstalled(_ model: LocalModelDefinition) -> Bool {
        _ = try? ensureCanonicalInstallation(for: model)
        return hasAllArtifacts(for: model, in: try? modelDirectory(modelId: model.id))
    }

    static func deleteModelDirectory(modelId: String) throws {
        let dir = try modelDirectory(modelId: modelId)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    static func loadModelConfig(modelId: String) -> ModelConfig? {
        guard let configURL = try? artifactURL(modelId: modelId, fileName: "config.json"),
            FileManager.default.fileExists(atPath: configURL.path),
            let data = try? Data(contentsOf: configURL),
            let config = try? JSONDecoder().decode(ModelConfig.self, from: data)
        else {
            return nil
        }
        return config
    }

    static func contextLength(for model: LocalModelDefinition) -> Int {
        _ = try? ensureCanonicalInstallation(for: model)
        // Try to load from config.json first
        if let config = loadModelConfig(modelId: model.id),
            let contextLength = config.contextLength
        {
            return contextLength
        }
        // Fall back to definition default
        return model.defaultContextLength
    }

    @discardableResult
    static func ensureCanonicalInstallation(for model: LocalModelDefinition) throws -> URL {
        let canonicalDirectory = try modelDirectory(modelId: model.id)
        try materializeCanonicalSymlinkIfNeeded(for: model, canonicalDirectory: canonicalDirectory)
        try migrateLegacyCacheIfNeeded(for: model, canonicalDirectory: canonicalDirectory)
        return canonicalDirectory
    }

    private static func hasAllArtifacts(for model: LocalModelDefinition, in directory: URL?) -> Bool {
        guard let directory else { return false }
        let fileManager = FileManager.default
        for artifact in model.artifacts {
            let artifactPath = directory.appendingPathComponent(artifact.fileName, isDirectory: false).path
            if !fileManager.fileExists(atPath: artifactPath) {
                return false
            }
        }
        return true
    }

    private static func materializeCanonicalSymlinkIfNeeded(
        for model: LocalModelDefinition,
        canonicalDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        guard isSymbolicLink(at: canonicalDirectory) else { return }

        let symlinkTarget = try resolvedSymlinkTarget(at: canonicalDirectory)
        let targetDirectory = symlinkTarget.standardizedFileURL

        guard hasAllArtifacts(for: model, in: targetDirectory) else { return }

        try fileManager.removeItem(at: canonicalDirectory)
        if fileManager.fileExists(atPath: canonicalDirectory.path) {
            try fileManager.removeItem(at: canonicalDirectory)
        }
        try fileManager.moveItem(at: targetDirectory, to: canonicalDirectory)
    }

    private static func migrateLegacyCacheIfNeeded(
        for model: LocalModelDefinition,
        canonicalDirectory: URL
    ) throws {
        guard !hasAllArtifacts(for: model, in: canonicalDirectory) else { return }

        // Pre-rename HF-style cache fallback. The old pre-rebrand app-support
        // location is gone — models now live exclusively under
        // `Application Support/Compass/local-models`.
        guard let legacyDirectory = legacyCacheDirectory(for: model) else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyDirectory.path),
              hasAllArtifacts(for: model, in: legacyDirectory) else {
            return
        }

        if fileManager.fileExists(atPath: canonicalDirectory.path) {
            try fileManager.removeItem(at: canonicalDirectory)
        }

        let canonicalParent = canonicalDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: canonicalParent, withIntermediateDirectories: true)
        try fileManager.moveItem(at: legacyDirectory, to: canonicalDirectory)
    }

    private static func legacyCacheDirectory(for model: LocalModelDefinition) -> URL? {
        guard let artifactURL = model.artifacts.first?.url,
              artifactURL.host == "huggingface.co" else {
            return nil
        }

        let pathComponents = artifactURL.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 4,
              pathComponents[2] == "resolve" else {
            return nil
        }

        let owner = pathComponents[0]
        let repository = pathComponents[1]

        #if DEBUG
        if let override = testRootOverride {
            // Sandboxed HF-style cache location for tests — never the real Caches dir.
            return override
                .appendingPathComponent("hf-cache", isDirectory: true)
                .appendingPathComponent(owner, isDirectory: true)
                .appendingPathComponent(repository, isDirectory: true)
        }
        #endif

        guard let cachesRoot = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }

        return cachesRoot
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(repository, isDirectory: true)
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
            return false
        }
        return values.isSymbolicLink == true
    }

    private static func resolvedSymlinkTarget(at symlinkURL: URL) throws -> URL {
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path)
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination, isDirectory: true)
        }
        return symlinkURL.deletingLastPathComponent()
            .appendingPathComponent(destination, isDirectory: true)
    }

    private static func prepareRuntimeCompatibilityDirectory(
        sourceDirectory: URL,
        model: LocalModelDefinition
    ) throws -> URL {
        let runtimeDirectory = sourceDirectory.appendingPathComponent("Compass-runtime", isDirectory: true)
        let normalizedChatTemplate = try normalizedRuntimeChatTemplateData(for: model)
        let templatePath = runtimeDirectory.appendingPathComponent("chat_template.jinja").path
        let configPath = runtimeDirectory.appendingPathComponent("config.json").path

        // Idempotent: skip recreation if directory and key files already exist
        if FileManager.default.fileExists(atPath: runtimeDirectory.path),
           FileManager.default.fileExists(atPath: templatePath),
           FileManager.default.fileExists(atPath: configPath) {
            return runtimeDirectory
        }

        if FileManager.default.fileExists(atPath: runtimeDirectory.path) {
            try FileManager.default.removeItem(at: runtimeDirectory)
        }
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)

        let fileManager = FileManager.default
        try validateRequiredRuntimeArtifacts(for: model, in: sourceDirectory)
        let sourceContents = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for sourceItem in sourceContents {
            guard sourceItem.lastPathComponent != runtimeDirectory.lastPathComponent else {
                continue
            }
            guard sourceItem.lastPathComponent != "config.json",
                  sourceItem.lastPathComponent != "chat_template.jinja" else {
                continue
            }

            let destinationItem = runtimeDirectory.appendingPathComponent(sourceItem.lastPathComponent)
            try fileManager.createSymbolicLink(at: destinationItem, withDestinationURL: sourceItem)
        }

        try normalizedRuntimeConfigData(for: model).write(
            to: runtimeDirectory.appendingPathComponent("config.json"),
            options: Data.WritingOptions.atomic
        )
        try normalizedChatTemplate.write(
            to: runtimeDirectory.appendingPathComponent("chat_template.jinja"),
            options: Data.WritingOptions.atomic
        )
        return runtimeDirectory
    }

    private static func validateRequiredRuntimeArtifacts(for model: LocalModelDefinition, in directory: URL) throws {
        let requiredArtifacts = requiredRuntimeArtifacts(for: model)
        guard !requiredArtifacts.isEmpty else { return }

        let fileManager = FileManager.default
        for artifact in requiredArtifacts {
            let path = directory.appendingPathComponent(artifact).path
            guard fileManager.fileExists(atPath: path) else {
                throw LocalModelFileStoreError.missingRequiredRuntimeArtifact(
                    modelId: model.id,
                    fileName: artifact
                )
            }
        }
    }

    private static func requiredRuntimeArtifacts(for model: LocalModelDefinition) -> [String] {
        // Fixed chat model (Qwen3.5-4B) — the VLM-style processor configs are
        // part of the repo and must be present for the runtime directory.
        _ = model
        return [
            "preprocessor_config.json",
            "processor_config.json",
            "video_preprocessor_config.json",
            "tokenizer.json",
            "tokenizer_config.json"
        ]
    }

    private static func normalizedRuntimeConfigData(for model: LocalModelDefinition) throws -> Data {
        let configURL = try artifactURL(modelId: model.id, fileName: "config.json")
        let originalData = try Data(contentsOf: configURL)

        guard var configObject = try JSONSerialization.jsonObject(with: originalData) as? [String: Any] else {
            return originalData
        }

        // Keep model_type as qwen3_5 — we load via LLM factory, not VLM.
        // The runtime compatibility directory is only needed for the custom
        // chat template that handles tool results correctly.
        if let textConfig = configObject["text_config"] as? [String: Any] {
            configObject["text_config"] = textConfig
        }

        return try JSONSerialization.data(withJSONObject: configObject, options: [.prettyPrinted])
    }

    private static func normalizedRuntimeChatTemplateData(for model: LocalModelDefinition) throws -> Data {
        _ = model
        return Data(qwen35JSONOnlyChatTemplate.utf8)
    }

    private static let qwen35JSONOnlyChatTemplate = #"""
{%- set image_count = namespace(value=0) %}
{%- set video_count = namespace(value=0) %}
{%- macro render_content(content, do_vision_count, is_system_content=false) %}
    {%- if content is string %}
        {{- content }}
    {%- elif content is iterable and content is not mapping %}
        {%- for item in content %}
            {%- if 'image' in item or 'image_url' in item or item.type == 'image' %}
                {%- if is_system_content %}
                    {{- raise_exception('System message cannot contain images.') }}
                {%- endif %}
                {%- if do_vision_count %}
                    {%- set image_count.value = image_count.value + 1 %}
                {%- endif %}
                {%- if add_vision_id %}
                    {{- 'Picture ' ~ image_count.value ~ ': ' }}
                {%- endif %}
                {{- '<|vision_start|><|image_pad|><|vision_end|>' }}
            {%- elif 'video' in item or item.type == 'video' %}
                {%- if is_system_content %}
                    {{- raise_exception('System message cannot contain videos.') }}
                {%- endif %}
                {%- if do_vision_count %}
                    {%- set video_count.value = video_count.value + 1 %}
                {%- endif %}
                {%- if add_vision_id %}
                    {{- 'Video ' ~ video_count.value ~ ': ' }}
                {%- endif %}
                {{- '<|vision_start|><|video_pad|><|vision_end|>' }}
            {%- elif 'text' in item %}
                {{- item.text }}
            {%- else %}
                {{- raise_exception('Unexpected item type in content.') }}
            {%- endif %}
        {%- endfor %}
    {%- elif content is none or content is undefined %}
        {{- '' }}
    {%- else %}
        {{- raise_exception('Unexpected content type.') }}
    {%- endif %}
{%- endmacro %}
{%- if not messages %}
    {{- raise_exception('No messages provided.') }}
{%- endif %}
{%- if tools and tools is iterable and tools is not mapping %}
    {{- '<|im_start|>system\n' }}
    {{- "# Tools\n\nYou have access to the following functions:\n\n<tools>" }}
    {%- for tool in tools %}
        {{- "\n" }}
        {{- tool | tojson }}
    {%- endfor %}
    {{- "\n</tools>" }}
    {{- '\n\nIf you choose to call a function ONLY reply in the following format with NO suffix:\n\n<tool_call>\n<function=example_function_name>\n<parameter=example_parameter_1>\nvalue_1\n</parameter>\n<parameter=example_parameter_2>\nThis is the value for the second parameter\nthat can span\nmultiple lines\n</parameter>\n</function>\n</tool_call>\n\n<IMPORTANT>\nReminder:\n- Function calls MUST follow the specified format: an inner <function=...></function> block must be nested within <tool_call></tool_call> XML tags\n- Required parameters MUST be specified\n- You may provide optional reasoning for your function call in natural language BEFORE the function call, but NOT after\n- If there is no function call available, answer the question like normal with your current knowledge and do not tell the user about function calls\n</IMPORTANT>' }}
    {%- if messages[0].role == 'system' %}
        {%- set content = render_content(messages[0].content, false, true)|trim %}
        {%- if content %}
            {{- '\n\n' + content }}
        {%- endif %}
    {%- endif %}
    {{- '<|im_end|>\n' }}
{%- else %}
    {%- if messages[0].role == 'system' %}
        {%- set content = render_content(messages[0].content, false, true)|trim %}
        {{- '<|im_start|>system\n' + content + '<|im_end|>\n' }}
    {%- endif %}
{%- endif %}
{%- set ns = namespace(last_query_index=messages|length - 1) %}
{%- for message in messages[::-1] %}
    {%- set index = (messages|length - 1) - loop.index0 %}
    {%- if message.role == "user" %}
        {%- set content = render_content(message.content, false)|trim %}
        {%- if not(content.startswith('<tool_result>') and content.endswith('</tool_result>')) %}
            {%- set ns.last_query_index = index %}
            {%- break %}
        {%- endif %}
    {%- endif %}
{%- endfor %}
{%- for message in messages %}
    {%- set content = render_content(message.content, true)|trim %}
    {%- if message.role == "system" %}
        {%- if not loop.first %}
            {{- raise_exception('System message must be at the beginning.') }}
        {%- endif %}
    {%- elif message.role == "user" %}
        {{- '<|im_start|>' + message.role + '\n' + content + '<|im_end|>' + '\n' }}
    {%- elif message.role == "assistant" %}
        {%- set reasoning_content = '' %}
        {%- if message.reasoning_content is string %}
            {%- set reasoning_content = message.reasoning_content %}
        {%- else %}
            {%- if '</think>' in content %}
                {%- set reasoning_content = content.split('</think>')[0].rstrip('\n').split('<think>')[-1].lstrip('\n') %}
                {%- set content = content.split('</think>')[-1].lstrip('\n') %}
            {%- endif %}
        {%- endif %}
        {%- set reasoning_content = reasoning_content|trim %}
        {%- if loop.index0 > ns.last_query_index %}
            {{- '<|im_start|>' + message.role + '\n<think>\n' + reasoning_content + '\n</think>\n\n' + content }}
        {%- else %}
            {{- '<|im_start|>' + message.role + '\n' + content }}
        {%- endif %}
        {%- if message.tool_calls and message.tool_calls is iterable and message.tool_calls is not mapping %}
            {%- for tool_call in message.tool_calls %}
                {%- if tool_call.function is defined %}
                    {%- set tool_call = tool_call.function %}
                {%- endif %}
                {%- if loop.first %}
                    {%- if content|trim %}
                        {{- '\n\n<tool_call>\n<function=' + tool_call.name + '>\n' }}
                    {%- else %}
                        {{- '<tool_call>\n<function=' + tool_call.name + '>\n' }}
                    {%- endif %}
                {%- else %}
                    {{- '\n<tool_call>\n<function=' + tool_call.name + '>\n' }}
                {%- endif %}
                {%- if tool_call.arguments is defined %}
                    {%- for args_name, args_value in tool_call.arguments|items %}
                        {{- '<parameter=' + args_name + '>\n' }}
                        {%- set args_value = args_value | tojson | safe if args_value is mapping or (args_value is sequence and args_value is not string) else args_value | string %}
                        {{- args_value }}
                        {{- '\n</parameter>\n' }}
                    {%- endfor %}
                {%- endif %}
                {{- '</function>\n</tool_call>' }}
            {%- endfor %}
        {%- endif %}
        {{- '<|im_end|>\n' }}
    {%- elif message.role == "tool" %}
        {%- if loop.previtem and loop.previtem.role != "tool" %}
            {{- '<|im_start|>user' }}
        {%- endif %}
        {{- '\n<tool_result>\n' }}
        {{- content }}
        {{- '\n</tool_result>' }}
        {%- if not loop.last and loop.nextitem.role != "tool" %}
            {{- '<|im_end|>\n' }}
        {%- elif loop.last %}
            {{- '<|im_end|>\n' }}
        {%- endif %}
    {%- endif %}
{%- endfor %}
{%- if add_generation_prompt %}
    {{- '<|im_start|>assistant\n' }}
    {%- if enable_thinking is defined and enable_thinking is false %}
        {{- '<think>\n\n</think>\n\n' }}
    {%- else %}
        {{- '<think>\n' }}
    {%- endif %}
{%- endif %}
"""#

    private static func sanitizeModelId(_ modelId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = modelId.unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) {
                return Character(scalar)
            }
            return "_"
        }
        return String(mapped)
    }
}
