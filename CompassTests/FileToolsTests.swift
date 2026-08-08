import XCTest
import Foundation
@testable import Compass

@MainActor
final class FileToolsTests: XCTestCase {

    func testFileOperationsWithCleanup() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test_file_\(UUID().uuidString).swift")

        // Track file for cleanup
        TestSupport.testFiles.append(testFile)

        // Create test file
        let testContent = "func testFunction() { print(\"Test\") }"
        try testContent.write(to: testFile, atomically: true, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: testFile.path), "Test file should be created")

        // Clean up test file
        try? FileManager.default.removeItem(at: testFile)
        TestSupport.testFiles.removeAll { $0 == testFile }

        XCTAssertFalse(FileManager.default.fileExists(atPath: testFile.path), "Test file should be cleaned up")
    }

    func testFileToolsSupportNestedPaths() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_file_tools_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let fileSystemService = FileSystemService()
        let validator = PathValidator(projectRoot: tempRoot)
        let eventBus = EventBus()

        let writeFileTool1 = WriteFileTool(fileSystemService: fileSystemService, pathValidator: validator, eventBus: eventBus)
        _ = try await writeFileTool1.execute(arguments: ToolArguments([
            "path": "src/pages/Register.tsx",
            "content": "export default function Register() { return null }\n",
            "_conversation_id": "file-tools-test"
        ]))

        let writeFileTool2 = WriteFileTool(fileSystemService: fileSystemService, pathValidator: validator, eventBus: eventBus)
        _ = try await writeFileTool2.execute(arguments: ToolArguments([
            "path": "src/components/Button.tsx",
            "content": "export function Button() { return null }\n",
            "_conversation_id": "file-tools-test"
        ]))

        let registerURL = tempRoot.appendingPathComponent("src/pages/Register.tsx")
        let buttonURL = tempRoot.appendingPathComponent("src/components/Button.tsx")

        XCTAssertTrue(FileManager.default.fileExists(atPath: registerURL.path), "Register.tsx should be written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: buttonURL.path), "Button.tsx should be written")

        let registerContent = try fileSystemService.readFile(at: registerURL)
        XCTAssertTrue(registerContent.contains("function Register"), "Register.tsx content should match")

        let writeFileTool3 = WriteFileTool(fileSystemService: fileSystemService, pathValidator: validator, eventBus: eventBus)
        _ = try await writeFileTool3.execute(arguments: ToolArguments([
            "path": "src/styles/app.css",
            "content": "",
            "_conversation_id": "file-tools-test"
        ]))

        let cssURL = tempRoot.appendingPathComponent("src/styles/app.css")
        let cssDirectoryURL = tempRoot.appendingPathComponent("src/styles", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cssDirectoryURL.path), "Nested write_file should prepare parent directories")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cssURL.path), "write_file should materialize the file")
    }

    func testFileToolsNormalizeProjectPseudoRootPaths() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_project_pseudoroot_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileSystemService = FileSystemService()
        let validator = PathValidator(projectRoot: tempRoot)
        let eventBus = EventBus()

        let writeFileTool = WriteFileTool(
            fileSystemService: fileSystemService,
            pathValidator: validator,
            eventBus: eventBus
        )
        _ = try await writeFileTool.execute(arguments: ToolArguments([
            "path": "/project/index.html",
            "content": "<html></html>"
        ]))

        let rootIndexURL = tempRoot.appendingPathComponent("index.html")
        let nestedProjectIndexURL = tempRoot.appendingPathComponent("project/index.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootIndexURL.path), "Pseudo-root /project/index.html should resolve to the real project root")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedProjectIndexURL.path), "Pseudo-root /project/index.html must not create a nested project directory")

        let writeFileTool3 = WriteFileTool(
            fileSystemService: fileSystemService,
            pathValidator: validator,
            eventBus: eventBus
        )
        _ = try await writeFileTool3.execute(arguments: ToolArguments([
            "path": "project/src/App.jsx",
            "content": "export default function App() { return null }",
            "_conversation_id": "file-tools-test"
        ]))

        let appDirectoryURL = tempRoot.appendingPathComponent("src", isDirectory: true)
        let nestedProjectAppURL = tempRoot.appendingPathComponent("project/src/App.jsx")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appDirectoryURL.path), "project/src/App.jsx should resolve to src/App.jsx under the real root")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedProjectAppURL.path), "project/src/App.jsx must not create a nested project directory")
    }

    func testReplaceInFileThrowsWhenOldTextDoesNotMatch() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_replace_error_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("config.txt")
        try "version=1.0\nname=current\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let tool = PatchFileToolAdapter(projectRoot: tempRoot)

        let result = try await tool.execute(arguments: ToolArguments([
            "path": "config.txt",
            "start_line": 1,
            "end_line": 5,
            "new_content": "version=1.0\nname=new\n"
        ]))
        XCTAssertTrue(result.localizedCaseInsensitiveContains("Invalid"), "Expected patch_file to report invalid line range")
    }

    func testWriteFileThrowsWhenPathAlreadyExists() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_write_error_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("existing.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let tool = WriteFileTool(
            fileSystemService: FileSystemService(),
            pathValidator: PathValidator(projectRoot: tempRoot),
            eventBus: EventBus()
        )

        do {
            _ = try await tool.execute(arguments: ToolArguments([
                "path": "existing.txt",
                "content": "world"
            ]))
            XCTFail("Expected write_file to throw when file already exists")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("Refused full-file overwrite"))
        }
    }

    func testWriteFileBlocksBlindFullOverwriteOfExistingFile() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_blind_overwrite_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("server.js")
        try "const app = createServer();\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let tool = WriteFileTool(
            fileSystemService: FileSystemService(),
            pathValidator: PathValidator(projectRoot: tempRoot),
            eventBus: EventBus()
        )

        do {
            _ = try await tool.execute(arguments: ToolArguments([
                "path": "server.js",
                "content": "import express from 'express'\nconst app = express()\n",
                "_conversation_id": "blind-overwrite-conversation"
            ]))
            XCTFail("Expected blind overwrite of existing file to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("refused full-file overwrite"))
        }
    }

    func testWriteFileAllowsFullRewriteAfterReadInSameConversation() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_read_then_rewrite_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("server.js")
        try "const app = createServer();\napp.listen(3000);\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let conversationId = "read-then-rewrite-conversation"
        let readTool = ReadFileTool(
            fileSystemService: FileSystemService(),
            pathValidator: PathValidator(projectRoot: tempRoot)
        )
        _ = try await readTool.execute(arguments: ToolArguments([
            "path": "server.js",
            "_conversation_id": conversationId
        ]))

        let writeTool = WriteFileTool(
            fileSystemService: FileSystemService(),
            pathValidator: PathValidator(projectRoot: tempRoot),
            eventBus: EventBus()
        )
        _ = try await writeTool.execute(arguments: ToolArguments([
            "path": "server.js",
            "content": "import express from 'express'\nconst app = express()\napp.listen(3000)\n",
            "_conversation_id": conversationId
        ]))

        let rewrittenContent = try String(contentsOf: fileURL)
        XCTAssertTrue(rewrittenContent.contains("import express from 'express'"), "Expected full rewrite to succeed after a same-conversation read")
    }

    func testWriteFileReturnsNoOpWhenContentAlreadyMatches() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_write_file_noop_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("index.html")
        let existingContent = "<!DOCTYPE html>\n<html></html>\n"
        try existingContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let tool = WriteFileTool(
            fileSystemService: FileSystemService(),
            pathValidator: PathValidator(projectRoot: tempRoot),
            eventBus: EventBus()
        )

        let result = try await tool.execute(arguments: ToolArguments([
            "path": "index.html",
            "content": existingContent,
            "_conversation_id": "same-content-noop"
        ]))

        XCTAssertTrue(result.localizedCaseInsensitiveContains("no-op"))
    }

    func testWriteFileRejectsAbsolutePathFromSiblingTemporaryRoot() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_path_root_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let siblingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_path_root_\(UUID().uuidString)_sibling")
        try FileManager.default.createDirectory(at: siblingRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: siblingRoot) }

        let siblingFile = siblingRoot.appendingPathComponent("src/math.ts")
        let tool = WriteFileTool(
            fileSystemService: FileSystemService(),
            pathValidator: PathValidator(projectRoot: tempRoot),
            eventBus: EventBus()
        )

        do {
            _ = try await tool.execute(arguments: ToolArguments([
                "path": siblingFile.path,
                "content": "export function add(a: number, b: number): number { return a + b }"
            ]))
            XCTFail("Expected sibling absolute path to be rejected as outside project root")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("outside the project directory"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent(String(siblingFile.path.dropFirst())).path))
    }

    func testReplaceInFileTreatsAlreadyAppliedStateAsNoOp() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_replace_noop_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("config.txt")
        try "version=1.0\nname=new\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let tool = PatchFileToolAdapter(projectRoot: tempRoot)

        let result = try await tool.execute(arguments: ToolArguments([
            "path": "config.txt",
            "start_line": 2,
            "end_line": 2,
            "new_content": "name=new"
        ]))

        XCTAssertTrue(result.localizedCaseInsensitiveContains("success"))
        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains("name=new"))
    }

    // MARK: - edit old_string/new_string mode (audit §1)

    func testEditOldStringReplacesUniqueMatchWithoutPriorRead() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_edit_oldstr_uniq_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("career-register.php")
        let original = """
        <?php
        /**
         * Plugin Name: Career Register
         * Version:     1.0.0
         */
        """
        try original.write(to: fileURL, atomically: true, encoding: .utf8)

        let tool = PatchFileToolAdapter(projectRoot: tempRoot)

        let result = try await tool.execute(arguments: ToolArguments([
            "path": "career-register.php",
            "old_string": " * Version:     1.0.0",
            "new_string": " * Version:     1.1.0"
        ]))

        XCTAssertTrue(result.localizedCaseInsensitiveContains("success"), "Expected success, got: \(result)")
        XCTAssertTrue(result.localizedCaseInsensitiveContains("1 match"), "Expected 1-match summary, got: \(result)")
        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains("1.1.0"), "Expected 1.1.0 in file, got: \(persisted)")
        XCTAssertFalse(persisted.contains("1.0.0"), "Old version should be gone, got: \(persisted)")
    }

    func testEditOldStringRejectsAmbiguousMatch() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_edit_oldstr_ambig_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("rules.php")
        try "add_action('init', 'career_register_init');\nadd_action('init', 'career_register_init');\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let tool = PatchFileToolAdapter(projectRoot: tempRoot)

        let result = try await tool.execute(arguments: ToolArguments([
            "path": "rules.php",
            "old_string": "add_action('init', 'career_register_init');",
            "new_string": "add_action('wp', 'career_register_init');"
        ]))

        XCTAssertTrue(result.localizedCaseInsensitiveContains("error"), "Expected error for ambiguous match, got: \(result)")
        XCTAssertTrue(result.localizedCaseInsensitiveContains("AMBIGUOUS_MATCH"), "Expected AMBIGUOUS_MATCH error code, got: \(result)")
        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains("init"), "File must be unchanged on refusal, got: \(persisted)")
    }

    func testEditOldStringRejectsMissingMatch() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_edit_oldstr_missing_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("career-register.php")
        try "<?php\n/**\n * Plugin Name: Other\n */\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let tool = PatchFileToolAdapter(projectRoot: tempRoot)

        let result = try await tool.execute(arguments: ToolArguments([
            "path": "career-register.php",
            "old_string": " * Version:     1.0.0",
            "new_string": " * Version:     1.1.0"
        ]))

        XCTAssertTrue(result.localizedCaseInsensitiveContains("error"), "Expected error for no match, got: \(result)")
        XCTAssertTrue(result.localizedCaseInsensitiveContains("OLD_STRING_NOT_FOUND"), "Expected OLD_STRING_NOT_FOUND, got: \(result)")
    }

    func testEditOldStringReplaceAllReplacesEveryOccurrence() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_edit_oldstr_all_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("salts.php")
        let original = "define('AUTH_KEY', 'old-salt');\ndefine('SECURE_AUTH_KEY', 'old-salt');\ndefine('LOGGED_IN_KEY', 'old-salt');\n"
        try original.write(to: fileURL, atomically: true, encoding: .utf8)

        let tool = PatchFileToolAdapter(projectRoot: tempRoot)

        let result = try await tool.execute(arguments: ToolArguments([
            "path": "salts.php",
            "old_string": "'old-salt'",
            "new_string": "'new-salt'",
            "replace_all": true
        ]))

        XCTAssertTrue(result.localizedCaseInsensitiveContains("success"), "Expected success for replace_all, got: \(result)")
        XCTAssertTrue(result.localizedCaseInsensitiveContains("3 match"), "Expected 3-match summary, got: \(result)")
        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(persisted.contains("old-salt"), "All old-salt should be replaced, got: \(persisted)")
        XCTAssertEqual(persisted.components(separatedBy: "new-salt").count - 1, 3, "Expected exactly 3 new-salt, got: \(persisted)")
    }

    func testEditOldStringEmptyNewStringDeletesMatch() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_edit_oldstr_delete_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("cleanup.txt")
        try "before\nDELETE_ME\nafter\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let tool = PatchFileToolAdapter(projectRoot: tempRoot)

        let result = try await tool.execute(arguments: ToolArguments([
            "path": "cleanup.txt",
            "old_string": "DELETE_ME\n",
            "new_string": ""
        ]))

        XCTAssertTrue(result.localizedCaseInsensitiveContains("success"), "Expected success, got: \(result)")
        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(persisted, "before\nafter\n", "Expected delete, got: \(persisted)")
    }

    func testEditRequiresEitherOldStringOrLineRangeArguments() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_edit_args_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("empty-rule.txt")
        try "hello\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let tool = PatchFileToolAdapter(projectRoot: tempRoot)

        let result = try await tool.execute(arguments: ToolArguments([
            "path": "empty-rule.txt"
        ]))

        XCTAssertTrue(result.localizedCaseInsensitiveContains("error"), "Expected error for missing args, got: \(result)")
        XCTAssertTrue(result.localizedCaseInsensitiveContains("MISSING_ARGUMENTS"), "Expected MISSING_ARGUMENTS, got: \(result)")
    }

    func testDeleteFileThrowsWhenPathDoesNotExist() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_delete_error_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let tool = DeleteFileTool(
            pathValidator: PathValidator(projectRoot: tempRoot),
            eventBus: EventBus()
        )

        do {
            _ = try await tool.execute(arguments: ToolArguments([
                "path": "missing.txt"
            ]))
            XCTFail("Expected delete_file to throw when file does not exist")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("does not exist"))
        }
    }
}
