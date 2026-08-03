import XCTest
@testable import Compass

@MainActor
final class PromptRepositoryTests: XCTestCase {

    /// Repo root derived from this file's location — never a literal home path,
    /// so the suite runs on any machine/CI checkout.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    
    func testPromptRepositoryFallbackDisabled() async {
        // This should succeed since the file exists
        let content: String
        do {
            content = try PromptRepository.shared.fallbackPrompt(
                key: "ConversationFlow/Corrections/empty_response_correction",
                defaultValue: "default value",
                allowFallback: false,
                projectRoot: repoRoot
            )
        } catch {
            XCTFail("Expected prompt load to succeed, got error: \(error)")
            return
        }
        
        // Should get the actual file content, not the default
        XCTAssertNotEqual(content, "default value")
        XCTAssertTrue(content.contains("visible response"))
    }
    
    func testPromptRepositoryFallbackEnabled() async {
        // This should return the default value since file doesn't exist but fallback is enabled
        let content: String
        do {
            content = try PromptRepository.shared.fallbackPrompt(
                key: "NonExistent/file",
                defaultValue: "default value",
                allowFallback: true,
                projectRoot: repoRoot
            )
        } catch {
            XCTFail("Expected fallback prompt load to succeed, got error: \(error)")
            return
        }
        
        XCTAssertEqual(content, "default value")
    }
    
    func testPromptRepositoryExistingFileWithFallbackEnabled() async {
        // This should still return the actual file content even with fallback enabled
        let content: String
        do {
            content = try PromptRepository.shared.fallbackPrompt(
                key: "ConversationFlow/Corrections/empty_response_correction",
                defaultValue: "default value",
                allowFallback: true,
                projectRoot: repoRoot
            )
        } catch {
            XCTFail("Expected prompt load to succeed, got error: \(error)")
            return
        }
        
        XCTAssertNotEqual(content, "default value")
        XCTAssertTrue(content.contains("visible response"))
    }
    
    func testPromptRepositoryPromptRemainsStrictWhenExplicitFallbackIsAllowed() async {
        XCTAssertThrowsError(
            try PromptRepository.shared.prompt(
                key: "NonExistent/file",
                projectRoot: repoRoot
            )
        ) { error in
            guard case AppError.promptLoadingFailed = error else {
                XCTFail("Expected AppError.promptLoadingFailed, got: \(error)")
                return
            }
        }
    }
    
    func testPromptRepositoryEmptyFileWithFallbackEnabled() async {
        // Create a temporary empty file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("empty_prompt.md")
        
        try? "   ".write(to: tempFile, atomically: true, encoding: .utf8)
        
        // This should return the default value since file is empty but fallback is enabled
        let content: String
        do {
            content = try PromptRepository.shared.fallbackPrompt(
                key: "empty_prompt",
                defaultValue: "default value",
                allowFallback: true,
                projectRoot: tempDir
            )
        } catch {
            XCTFail("Expected fallback for empty prompt file, got error: \(error)")
            return
        }
        
        XCTAssertEqual(content, "default value")
        
        // Clean up
        try? FileManager.default.removeItem(at: tempFile)
    }

    func testPromptRepositoryMissingPromptThrowsWhenFallbackDisabled() async {
        XCTAssertThrowsError(
            try PromptRepository.shared.fallbackPrompt(
                key: "NonExistent/file",
                defaultValue: "default value",
                allowFallback: false,
                projectRoot: repoRoot
            )
        ) { error in
            guard case AppError.promptLoadingFailed = error else {
                XCTFail("Expected AppError.promptLoadingFailed, got: \(error)")
                return
            }
        }
    }
}
