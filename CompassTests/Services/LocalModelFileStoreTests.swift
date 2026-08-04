import XCTest

@testable import Compass

final class LocalModelFileStoreTests: XCTestCase {
    private let qwen35ModelId = "mlx-community/Qwen3.5-4B-MLX-4bit@main"

    override func setUpWithError() throws {
        // Critical isolation: these tests install fixtures and delete model
        // directories on teardown. They MUST run against a sandboxed temp
        // root — the real Application Support / Caches model directories are
        // the user's actual downloaded models and were deleted by this suite
        // before the override existed (regression: Qwen3.5-4B-MLX-4bit).
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        testSandbox = sandbox
        LocalModelFileStore.testRootOverride = sandbox
    }

    private var testSandbox: URL?

    override func tearDownWithError() throws {
        LocalModelFileStore.testRootOverride = nil
        if let sandbox = testSandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        testSandbox = nil
        try super.tearDownWithError()
    }

    func testContextLengthReadsNestedTextConfigForQwen35() throws {
        let model = try XCTUnwrap(LocalModelCatalog.model(id: qwen35ModelId))
        try installQwen35FixtureConfig()

        XCTAssertEqual(LocalModelFileStore.contextLength(for: model), 262144)
    }

    func testRuntimeModelDirectoryUsesInstalledQwen35DirectoryForCurrentMLXRuntime() throws {
        let model = try XCTUnwrap(LocalModelCatalog.model(id: qwen35ModelId))
        try installQwen35FixtureConfig()

        let runtimeDirectory = try LocalModelFileStore.chatRuntimeModelDirectory()
        let runtimeConfigURL = runtimeDirectory.appendingPathComponent("config.json")
        let runtimeConfigData = try Data(contentsOf: runtimeConfigURL)
        let runtimeConfigObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: runtimeConfigData) as? [String: Any]
        )
        let textConfigObject = try XCTUnwrap(runtimeConfigObject["text_config"] as? [String: Any])

        XCTAssertEqual(
            runtimeDirectory,
            try LocalModelFileStore.modelDirectory(modelId: qwen35ModelId)
                .appendingPathComponent("Compass-runtime")
        )
        XCTAssertEqual(runtimeConfigObject["model_type"] as? String, "qwen3_5")
        XCTAssertEqual(textConfigObject["model_type"] as? String, "qwen3")
        XCTAssertEqual(textConfigObject["max_position_embeddings"] as? Int, 262144)
        XCTAssertEqual(textConfigObject["hidden_size"] as? Int, 2560)
    }

    func testEnsureCanonicalInstallationMovesLegacyCacheDirectory() throws {
        let model = try XCTUnwrap(LocalModelCatalog.model(id: qwen35ModelId))
        let canonicalDirectory = try LocalModelFileStore.modelDirectory(modelId: qwen35ModelId)
        let legacyDirectory = try XCTUnwrap(legacyCacheDirectory(for: model))
        try installAllArtifacts(for: model, in: legacyDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalDirectory.path))

        let installedDirectory = try LocalModelFileStore.ensureCanonicalInstallation(for: model)

        XCTAssertEqual(installedDirectory, canonicalDirectory)
        XCTAssertTrue(LocalModelFileStore.isModelInstalled(model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDirectory.path))
        XCTAssertFalse(isSymlink(at: canonicalDirectory))
    }

    func testEnsureCanonicalInstallationMaterializesSymlinkedDirectory() throws {
        let model = try XCTUnwrap(LocalModelCatalog.model(id: qwen35ModelId))
        let canonicalDirectory = try LocalModelFileStore.modelDirectory(modelId: qwen35ModelId)
        let legacyDirectory = try XCTUnwrap(legacyCacheDirectory(for: model))
        let canonicalParent = canonicalDirectory.deletingLastPathComponent()

        try installAllArtifacts(for: model, in: legacyDirectory)
        try FileManager.default.createDirectory(at: canonicalParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: canonicalDirectory, withDestinationURL: legacyDirectory)

        let installedDirectory = try LocalModelFileStore.ensureCanonicalInstallation(for: model)

        XCTAssertEqual(installedDirectory, canonicalDirectory)
        XCTAssertTrue(LocalModelFileStore.isModelInstalled(model))
        XCTAssertFalse(isSymlink(at: canonicalDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDirectory.path))
    }

    private static let requiredRuntimeArtifacts = [
        "preprocessor_config.json",
        "processor_config.json",
        "video_preprocessor_config.json",
        "tokenizer.json",
        "tokenizer_config.json"
    ]

    private func installQwen35FixtureConfig() throws {
        let modelDirectory = try LocalModelFileStore.modelDirectory(modelId: qwen35ModelId)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        for artifact in Self.requiredRuntimeArtifacts {
            try "{}".write(
                to: modelDirectory.appendingPathComponent(artifact),
                atomically: true,
                encoding: .utf8
            )
        }

        let config = """
        {
          "architectures": ["Qwen3_5ForConditionalGeneration"],
          "model_type": "qwen3_5",
          "image_token_id": 248056,
          "text_config": {
            "model_type": "qwen3",
            "max_position_embeddings": 262144,
            "hidden_size": 2560,
            "intermediate_size": 9216,
            "num_hidden_layers": 32,
            "num_attention_heads": 32,
            "num_key_value_heads": 8,
            "rms_norm_eps": 0.000001,
            "vocab_size": 151936,
            "head_dim": 256,
            "rope_theta": 1000000,
            "tie_word_embeddings": false
          },
          "quantization": {
            "group_size": 64,
            "bits": 4,
            "mode": "affine"
          }
        }
        """

        try config.write(
            to: modelDirectory.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func installAllArtifacts(for model: LocalModelDefinition, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for artifact in model.artifacts {
            try "{}".write(
                to: directory.appendingPathComponent(artifact.fileName),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func legacyCacheDirectory(for model: LocalModelDefinition) -> URL? {
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

        // Resolve under the sandboxed override root — never the real Caches dir.
        guard let override = LocalModelFileStore.testRootOverride else {
            XCTFail("LocalModelFileStoreTests must run with testRootOverride set")
            return nil
        }

        return override
            .appendingPathComponent("hf-cache", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(repository, isDirectory: true)
    }

    private func isSymlink(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
            return false
        }
        return values.isSymbolicLink == true
    }
}
