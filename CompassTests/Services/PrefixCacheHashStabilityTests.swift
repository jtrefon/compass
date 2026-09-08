import XCTest
@testable import Compass

final class PrefixCacheHashStabilityTests: XCTestCase {

    // MARK: - canonicalJSON determinism

    func testCanonicalJSONIsDeterministic() throws {
        let dict: [String: Any] = [
            "name": "read",
            "description": "Read a file",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File path"]
                ]
            ]
        ]

        let result1 = LocalModelProcessAIService.canonicalJSON(dict)
        let result2 = LocalModelProcessAIService.canonicalJSON(dict)

        XCTAssertNotNil(result1)
        XCTAssertEqual(result1, result2, "canonicalJSON must be deterministic for the same input")
    }

    func testCanonicalJSONIsKeyOrderIndependent() throws {
        let dictA: [String: Any] = [
            "name": "read",
            "description": "Read a file",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "File path"]
                ]
            ]
        ]
        let dictB: [String: Any] = [
            "description": "Read a file",
            "parameters": [
                "properties": [
                    "path": ["description": "File path", "type": "string"]
                ],
                "type": "object"
            ],
            "name": "read"
        ]

        let resultA = LocalModelProcessAIService.canonicalJSON(dictA)
        let resultB = LocalModelProcessAIService.canonicalJSON(dictB)

        XCTAssertEqual(resultA, resultB, "canonicalJSON must produce the same output regardless of key insertion order")
    }

    func testCanonicalJSONArrayOrderPreserved() throws {
        let arrayA: [Any] = [
            ["name": "read"],
            ["name": "write"]
        ]
        let arrayB: [Any] = [
            ["name": "read"],
            ["name": "write"]
        ]

        let resultA = LocalModelProcessAIService.canonicalJSON(arrayA)
        let resultB = LocalModelProcessAIService.canonicalJSON(arrayB)

        XCTAssertEqual(resultA, resultB)
    }

    func testCanonicalJSONArrayOrderMatters() throws {
        let arrayA: [Any] = [
            ["name": "read"],
            ["name": "write"]
        ]
        let arrayB: [Any] = [
            ["name": "write"],
            ["name": "read"]
        ]

        let resultA = LocalModelProcessAIService.canonicalJSON(arrayA)
        let resultB = LocalModelProcessAIService.canonicalJSON(arrayB)

        XCTAssertNotEqual(resultA, resultB, "different array orders should produce different canonical JSON")
    }

    // MARK: - computePrefixHash stability

    func testHashStableAcrossIdenticalInputs() throws {
        let systemContent = "# Tools\n\nYou have access to the following functions:\n\n"
        let toolSpecs = sampleToolSpecs()
        let modelId = "qwen3.5-4b"
        let additionalContext: [String: any Sendable] = ["enable_thinking": true]
        let kv4Bit = true

        let hash1 = LocalModelProcessAIService.computePrefixHash(
            systemContent: systemContent,
            toolSpecs: toolSpecs,
            modelId: modelId,
            additionalContext: additionalContext,
            kv4BitEnabled: kv4Bit
        )

        let hash2 = LocalModelProcessAIService.computePrefixHash(
            systemContent: systemContent,
            toolSpecs: toolSpecs,
            modelId: modelId,
            additionalContext: additionalContext,
            kv4BitEnabled: kv4Bit
        )

        XCTAssertEqual(hash1, hash2, "Hash must be identical for identical inputs (simulates stage nil vs tool_loop)")
    }

    func testHashChangesWithDifferentTools() throws {
        let systemContent = "# Tools\n\nYou have access to the following functions:\n\n"
        let modelId = "qwen3.5-4b"
        let additionalContext: [String: any Sendable] = ["enable_thinking": true]
        let kv4Bit = true

        let hashWithTools = LocalModelProcessAIService.computePrefixHash(
            systemContent: systemContent,
            toolSpecs: sampleToolSpecs(),
            modelId: modelId,
            additionalContext: additionalContext,
            kv4BitEnabled: kv4Bit
        )

        let hashWithoutTools = LocalModelProcessAIService.computePrefixHash(
            systemContent: systemContent,
            toolSpecs: nil,
            modelId: modelId,
            additionalContext: additionalContext,
            kv4BitEnabled: kv4Bit
        )

        XCTAssertNotEqual(hashWithTools, hashWithoutTools, "Hash must differ when tools are present vs absent")
    }

    func testHashStableWithSameToolsDifferentInstances() throws {
        let systemContent = "# Tools\n\nYou have access to the following functions:\n\n"
        let modelId = "qwen3.5-4b"
        let additionalContext: [String: any Sendable] = ["enable_thinking": true]
        let kv4Bit = true

        let tools1 = sampleToolSpecs()
        let tools2 = sampleToolSpecs()

        let hash1 = LocalModelProcessAIService.computePrefixHash(
            systemContent: systemContent,
            toolSpecs: tools1,
            modelId: modelId,
            additionalContext: additionalContext,
            kv4BitEnabled: kv4Bit
        )

        let hash2 = LocalModelProcessAIService.computePrefixHash(
            systemContent: systemContent,
            toolSpecs: tools2,
            modelId: modelId,
            additionalContext: additionalContext,
            kv4BitEnabled: kv4Bit
        )

        XCTAssertEqual(hash1, hash2, "Identical tool sets (different object instances) must produce the same hash")
    }

    func testHashChangesWithSystemContent() throws {
        let toolSpecs = sampleToolSpecs()
        let modelId = "qwen3.5-4b"
        let additionalContext: [String: any Sendable] = ["enable_thinking": true]
        let kv4Bit = true

        let hash1 = LocalModelProcessAIService.computePrefixHash(
            systemContent: "# Tools\n\nVersion A",
            toolSpecs: toolSpecs,
            modelId: modelId,
            additionalContext: additionalContext,
            kv4BitEnabled: kv4Bit
        )

        let hash2 = LocalModelProcessAIService.computePrefixHash(
            systemContent: "# Tools\n\nVersion A ", // trailing space
            toolSpecs: toolSpecs,
            modelId: modelId,
            additionalContext: additionalContext,
            kv4BitEnabled: kv4Bit
        )

        XCTAssertNotEqual(hash1, hash2, "Trailing whitespace in system content changes the hash (expected — the renderer normalizes, the hash is byte-exact)")
    }

    func testHashStableWithKV4BitDisabled() throws {
        let systemContent = "# Tools\n\n"
        let toolSpecs = sampleToolSpecs()
        let modelId = "qwen3.5-4b"
        let additionalContext: [String: any Sendable] = ["enable_thinking": true]

        let hash1 = LocalModelProcessAIService.computePrefixHash(
            systemContent: systemContent,
            toolSpecs: toolSpecs,
            modelId: modelId,
            additionalContext: additionalContext,
            kv4BitEnabled: false
        )

        let hash2 = LocalModelProcessAIService.computePrefixHash(
            systemContent: systemContent,
            toolSpecs: toolSpecs,
            modelId: modelId,
            additionalContext: additionalContext,
            kv4BitEnabled: false
        )

        XCTAssertEqual(hash1, hash2)
    }

    func testHashDiffersByModelId() throws {
        let systemContent = "# Tools\n\n"
        let toolSpecs = sampleToolSpecs()
        let additionalContext: [String: any Sendable] = ["enable_thinking": true]

        let hashA = LocalModelProcessAIService.computePrefixHash(
            systemContent: systemContent,
            toolSpecs: toolSpecs,
            modelId: "qwen3.5-4b",
            additionalContext: additionalContext,
            kv4BitEnabled: true
        )

        let hashB = LocalModelProcessAIService.computePrefixHash(
            systemContent: systemContent,
            toolSpecs: toolSpecs,
            modelId: "qwen3.5-8b",
            additionalContext: additionalContext,
            kv4BitEnabled: true
        )

        XCTAssertNotEqual(hashA, hashB, "Different model IDs must produce different hashes")
    }

    // MARK: - Helpers

    private func sampleToolSpecs() -> [[String: any Sendable]] {
        [
            [
                "type": "function",
                "function": [
                    "name": "read",
                    "description": "Read a file from disk",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "The file path to read"
                            ]
                        ],
                        "required": ["path"]
                    ] as [String: any Sendable]
                ] as [String: any Sendable]
            ] as [String: any Sendable],
            [
                "type": "function",
                "function": [
                    "name": "bash",
                    "description": "Run a shell command",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": [
                                "type": "string",
                                "description": "The command to run"
                            ]
                        ],
                        "required": ["command"]
                    ] as [String: any Sendable]
                ] as [String: any Sendable]
            ] as [String: any Sendable]
        ]
    }
}
