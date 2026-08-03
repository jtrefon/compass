import XCTest
import Foundation
@testable import Compass

@MainActor
final class AppStateEditorTests: XCTestCase {

    func testAppStateInitialization() async throws {
        let appState = DependencyContainer().makeAppState()

        XCTAssertNil(appState.fileEditor.selectedFile, "Selected file should be nil initially")
        XCTAssertTrue(appState.fileEditor.editorContent.isEmpty, "Editor content should be empty initially")
        XCTAssertEqual(appState.fileEditor.editorLanguage, "swift", "Default language should be swift")
        XCTAssertFalse(appState.fileEditor.isDirty, "Should not be dirty initially")
        XCTAssertNil(appState.lastError, "Should have no errors initially")

        // Workspace can be nil until the user explicitly selects a folder.
        if let dir = appState.workspace.currentDirectory {
            var isDir: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue,
                "If set, currentDirectory must exist and be a directory"
            )
        }
    }

    func testLanguageDetection() async throws {
        XCTAssertEqual(
            FileEditorStateManager.languageForFileExtension("swift"), "swift",
            "Swift files should detect as swift"
        )
        XCTAssertEqual(
            FileEditorStateManager.languageForFileExtension("js"), "javascript",
            "JS files should detect as javascript"
        )
        XCTAssertEqual(
            FileEditorStateManager.languageForFileExtension("jsx"), "javascript",
            "JSX files should detect as javascript"
        )
        XCTAssertEqual(
            FileEditorStateManager.languageForFileExtension("ts"), "typescript",
            "TS files should detect as typescript"
        )
        XCTAssertEqual(
            FileEditorStateManager.languageForFileExtension("tsx"), "tsx",
            "TSX files should detect as tsx"
        )
        XCTAssertEqual(
            FileEditorStateManager.languageForFileExtension("py"), "python",
            "Python files should detect as python"
        )
        XCTAssertEqual(
            FileEditorStateManager.languageForFileExtension("html"), "html",
            "HTML files should detect as html"
        )
        XCTAssertEqual(
            FileEditorStateManager.languageForFileExtension("css"), "css",
            "CSS files should detect as css"
        )
        XCTAssertEqual(
            FileEditorStateManager.languageForFileExtension("json"), "json",
            "JSON files should detect as json"
        )
        XCTAssertEqual(
            FileEditorStateManager.languageForFileExtension("unknown"), "text",
            "Unknown files should default to text"
        )
        XCTAssertEqual(
            FileEditorStateManager.languageForFileExtension(""), "text",
            "Empty extension should default to text"
        )
    }

    func testNewFileFunctionality() async throws {
        let appState = DependencyContainer().makeAppState()

        appState.fileEditor.editorContent = "some content"
        // appState.fileEditor.selectedFile and .isDirty are read-only

        appState.fileEditor.newFile()

        XCTAssertNil(appState.fileEditor.selectedFile, "Selected file should be nil after new")
        XCTAssertTrue(appState.fileEditor.editorContent.isEmpty, "Editor content should be empty after new")
        XCTAssertFalse(appState.fileEditor.isDirty, "Should not be dirty after new")
        XCTAssertNil(appState.lastError, "Should have no errors after new")
    }

    func testEditorTabsNoDuplicatesOnRepeatedOpen() async throws {
        let appState = DependencyContainer().makeAppState()

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Compass_tabs_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let file = tempRoot.appendingPathComponent("a.swift")
        try "print(\"hello\")".write(to: file, atomically: true, encoding: .utf8)

        appState.fileEditor.loadFile(from: file)
        appState.fileEditor.loadFile(from: file)

        XCTAssertEqual(
            appState.fileEditor.tabs.count, 1,
            "Opening same file twice should not create duplicate tabs"
        )
        XCTAssertEqual(appState.fileEditor.selectedFile, file.path, "Expected selectedFile to be the opened file")
    }

    func testOpenJSONFileSetsEditorLanguageToJSON() async throws {
        let appState = DependencyContainer().makeAppState()

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Compass_open_json_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let file = tempRoot.appendingPathComponent("data.json")
        try "{\"a\": 1, \"b\": true, \"c\": null}".write(to: file, atomically: true, encoding: .utf8)

        appState.fileEditor.loadFile(from: file)

        XCTAssertEqual(appState.fileEditor.selectedFile, file.path)
        XCTAssertEqual(
            appState.fileEditor.editorLanguage, "json",
            "Expected .json files to set editorLanguage=json"
        )
    }

    func testUntitledBufferAutoDetectsJSONLanguageOnPaste() async throws {
        let appState = DependencyContainer().makeAppState()

        appState.fileEditor.newFile()
        XCTAssertNil(appState.fileEditor.selectedFile)
        XCTAssertEqual(appState.fileEditor.editorLanguage, "swift")

        let pasted = """
        {
          \"key\": \"value\",
          \"n\": 1,
          \"b\": true,
          \"z\": null
        }
        """

        appState.fileEditor.editorContent = pasted
        XCTAssertEqual(
            appState.fileEditor.editorLanguage, "json",
            "Expected pasted JSON in untitled buffer to auto-switch editorLanguage to json"
        )
    }

    func testEditorCloseActiveTabClearsStateWhenLastTab() async throws {
        let appState = DependencyContainer().makeAppState()

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Compass_tabs_close_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let file = tempRoot.appendingPathComponent("a.swift")
        try "print(\"hello\")".write(to: file, atomically: true, encoding: .utf8)

        appState.fileEditor.loadFile(from: file)
        XCTAssertEqual(appState.fileEditor.tabs.count, 1)

        appState.fileEditor.closeActiveTab()

        XCTAssertTrue(appState.fileEditor.tabs.isEmpty, "Expected no tabs after closing last tab")
        XCTAssertNil(
            appState.fileEditor.selectedFile,
            "Expected selectedFile to be nil after closing last tab"
        )
    }

    func testSplitEditorOpenTargetsFocusedPane() async throws {
        let appState = DependencyContainer().makeAppState()

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Compass_split_focus_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileA = tempRoot.appendingPathComponent("a.swift")
        let fileB = tempRoot.appendingPathComponent("b.swift")
        try "print(\"a\")".write(to: fileA, atomically: true, encoding: .utf8)
        try "print(\"b\")".write(to: fileB, atomically: true, encoding: .utf8)

        appState.fileEditor.toggleSplit(axis: FileEditorStateManager.SplitAxis.vertical)
        appState.fileEditor.focus(FileEditorStateManager.PaneID.secondary)

        appState.fileEditor.loadFile(from: fileB)

        XCTAssertTrue(appState.fileEditor.isSplitEditor, "Expected split editor to be enabled")
        XCTAssertTrue(
            appState.fileEditor.secondaryPane.tabs.contains(where: { $0.filePath == fileB.path }),
            "Expected file to open in secondary pane"
        )
        XCTAssertFalse(
            appState.fileEditor.primaryPane.tabs.contains(where: { $0.filePath == fileB.path }),
            "Expected file not to open in primary pane"
        )
    }
}
