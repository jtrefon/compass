import Foundation
@preconcurrency import MLXLMCommon

enum LocalModelCatalog {
    /// The single fixed chat/inference model (local MLX pipeline).
    static let chatModel = qwen3_5_4B_MLX_4bit()

    /// The single fixed FIM (inline completion) model.
    static let fimModel = qwen25Coder15BInstruct4bit()

    /// Resolves a stored model ID against the fixed internal models.
    /// The stored `LocalModel.SelectedId` always matches `chatModel`; the
    /// lookup exists so persisted selections keep resolving after upgrades.
    static func model(id: String) -> LocalModelDefinition? {
        [chatModel, fimModel].first(where: { $0.id == id })
    }

    private static func makeURL(base: String, fileName: String) -> URL {
        let fullString = base + fileName
        if let url = URL(string: fullString) {
            return url
        }
        if let escapedString = fullString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: escapedString) {
            return url
        }
        return URL(string: "https://huggingface.co")!
    }

    private static func qwen3_5_4B_MLX_4bit() -> LocalModelDefinition {
        let base = "https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit/resolve/main/"

        func artifact(_ fileName: String) -> LocalModelArtifact {
            LocalModelArtifact(fileName: fileName, url: makeURL(base: base, fileName: fileName))
        }

        return LocalModelDefinition(
            id: "mlx-community/Qwen3.5-4B-MLX-4bit@main",
            displayName: "Local Model",
            artifacts: [
                artifact("chat_template.jinja"),
                artifact("config.json"),
                artifact("model.safetensors"),
                artifact("model.safetensors.index.json"),
                artifact("preprocessor_config.json"),
                artifact("processor_config.json"),
                artifact("tokenizer.json"),
                artifact("tokenizer_config.json"),
                artifact("video_preprocessor_config.json"),
                artifact("vocab.json")
            ],
            defaultContextLength: 65536
        )
    }

    private static func qwen25Coder15BInstruct4bit() -> LocalModelDefinition {
        let base = "https://huggingface.co/mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit/resolve/main/"

        func artifact(_ fileName: String) -> LocalModelArtifact {
            LocalModelArtifact(fileName: fileName, url: makeURL(base: base, fileName: fileName))
        }

        return LocalModelDefinition(
            id: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit@main",
            displayName: "Qwen2.5-Coder-1.5B (Fast)",
            artifacts: [
                artifact("config.json"),
                artifact("model.safetensors"),
                artifact("tokenizer.json"),
                artifact("tokenizer_config.json"),
                artifact("vocab.json"),
                artifact("merges.txt")
            ],
            defaultContextLength: 32768
        )
    }
}
