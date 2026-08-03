import XCTest
import Foundation
@testable import Compass

@MainActor
final class SearchNavigationTests: XCTestCase {

    func testQuickOpenParseQuerySupportsLineSuffix() async throws {
        let parsed1 = QuickOpenOverlayView.parseQuery("Sources/Foo.swift:12")
        XCTAssertEqual(parsed1.fileQuery, "Sources/Foo.swift")
        XCTAssertEqual(parsed1.line, 12)

        let parsed2 = QuickOpenOverlayView.parseQuery("Foo.swift")
        XCTAssertEqual(parsed2.fileQuery, "Foo.swift")
        XCTAssertNil(parsed2.line)
    }

    func testWorkspaceSearchParseIndexedMatchLine() async throws {
        let parsedMatch = WorkspaceSearchService.parseIndexedMatchLine("src/main.swift:42: print(\"hi\")")
        XCTAssertEqual(parsedMatch?.relativePath, "src/main.swift")
        XCTAssertEqual(parsedMatch?.line, 42)
        XCTAssertEqual(parsedMatch?.snippet, "print(\"hi\")")
    }

    func testWorkspaceSearchFallbackFindsMatches() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_global_search_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let file = tempRoot.appendingPathComponent("a.swift")
        try "let x = 1\nlet y = 2\nprint(\"needle\")\n".write(to: file, atomically: true, encoding: .utf8)

        let svc = WorkspaceSearchService(codebaseIndexProvider: { nil })
        let results = await svc.search(pattern: "needle", projectRoot: tempRoot, limit: 20)
        let found = results.first(where: { $0.relativePath == "a.swift" })
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.line, 3)
    }

    func testCommandPaletteScoring() async throws {
        let exact = CommandPaletteScoring.score(candidate: "workbench.quickOpen", query: "workbench.quickOpen")
        let prefix = CommandPaletteScoring.score(candidate: "workbench.quickOpen", query: "work")
        let contains = CommandPaletteScoring.score(candidate: "workbench.quickOpen", query: "quick")
        let miss = CommandPaletteScoring.score(candidate: "workbench.quickOpen", query: "nope")

        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, contains)
        XCTAssertGreaterThan(contains, 0)
        XCTAssertEqual(miss, 0)
    }

    func testGoToSymbolFallbackParsesSwift() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Compass_goto_symbol_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let file = tempRoot.appendingPathComponent("a.swift")
        let content = """
        import Foundation

        class Foo {
            func bar() {}
        }

        struct Baz {}
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let svc = WorkspaceSymbolSearchService(codebaseIndexProvider: { nil })
        let results = await svc.search(
            WorkspaceSymbolSearchService.SearchRequest(
                rawQuery: "Foo",
                projectRoot: tempRoot,
                currentFilePath: file.path,
                currentContent: content,
                currentLanguage: "swift",
                limit: 20
            )
        )

        let foundFoo = results.first(where: { $0.name == "Foo" })
        XCTAssertNotNil(foundFoo)
        XCTAssertEqual(foundFoo?.relativePath, "a.swift")

        let lines = content.components(separatedBy: "\n")
        let expectedLine = (lines.firstIndex(where: { $0.contains("class Foo") }) ?? 0) + 1
        XCTAssertEqual(foundFoo?.line, expectedLine)
    }

    func testWorkspaceNavigationIdentifierAtCursor() async throws {
        let text = "let fooBar = 1\nprint(fooBar)\n"
        let ns = text as NSString
        let cursor = ns.range(of: "fooBar").location + 2
        let ident = WorkspaceNavigationService.identifierAtCursor(in: text, cursor: cursor)
        XCTAssertEqual(ident, "fooBar")

        let cursorOnWhitespace = ns.range(of: "print").location - 1
        let none = WorkspaceNavigationService.identifierAtCursor(in: text, cursor: cursorOnWhitespace)
        XCTAssertNil(none)
    }

    func testWorkspaceNavigationRenameInCurrentBufferWholeWord() async throws {
        let content = "let foo = 1\nlet foobar = 2\nfoo = foo + 1\n"
        let result = try WorkspaceNavigationService.renameInCurrentBuffer(content: content, identifier: "foo", newName: "bar")
        XCTAssertEqual(result.replacements, 3)
        XCTAssertTrue(result.updated.contains("let bar = 1"))
        XCTAssertTrue(result.updated.contains("let foobar = 2"))
        XCTAssertTrue(result.updated.contains("bar = bar + 1"))
    }

    func testWorkspaceNavigationRenameRejectsInvalidIdentifier() async throws {
        do {
            _ = try WorkspaceNavigationService.renameInCurrentBuffer(content: "let foo = 1", identifier: "foo", newName: "1bad")
            XCTFail("Expected rename to throw for invalid identifier")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("invalid identifier"))
        }
    }

    func testDiagnosticsParserParsesXcodebuildErrorLine() async throws {
        let line = "/Users/me/Project/Foo.swift:42:13: error: Cannot find 'Bar' in scope"
        let parsedDiagnostic = DiagnosticsParser.parseXcodebuildLine(line)
        XCTAssertNotNil(parsedDiagnostic)
        XCTAssertEqual(parsedDiagnostic?.relativePath, "/Users/me/Project/Foo.swift")
        XCTAssertEqual(parsedDiagnostic?.line, 42)
        XCTAssertEqual(parsedDiagnostic?.column, 13)
        XCTAssertEqual(parsedDiagnostic?.severity, .error)
        XCTAssertTrue(parsedDiagnostic?.message.contains("Cannot find") == true)
    }

    func testCodeFoldingRangeFinderFindsBraceFoldRangeAtCursor() async throws {
        let content = """
        func foo() {
            print(\"a\")
            if true {
                print(\"b\")
            }
        }
        """

        let ns = content as NSString
        let cursor = ns.range(of: "print(\"b\")").location
        let foldRange = CodeFoldingRangeFinder.foldRange(at: cursor, in: content)
        XCTAssertNotNil(foldRange)
        XCTAssertGreaterThan(foldRange?.length ?? 0, 0)

        // The smallest containing fold should be the inner `if` block, not the outer function.
        let foldedText = ns.substring(with: foldRange!)
        XCTAssertTrue(foldedText.contains("print(\"b\")"))
        XCTAssertFalse(foldedText.contains("print(\"a\")"))
    }

    func testCodeFoldingRangeFinderReturnsAllFoldRanges() async throws {
        let content = """
        struct A {
            func foo() {
                print(\"x\")
            }
        }
        """

        let ranges = CodeFoldingRangeFinder.allFoldRanges(in: content)
        XCTAssertEqual(ranges.count, 2)
    }

    func testMultiCursorUtilitiesNextOccurrence() async throws {
        let text = "foo bar foo baz foo"
        let r1 = MultiCursorUtilities.nextOccurrenceRange(text: text, needle: "foo", fromIndex: 0)
        XCTAssertEqual(r1?.location, 0)

        let r2 = MultiCursorUtilities.nextOccurrenceRange(text: text, needle: "foo", fromIndex: 1)
        XCTAssertEqual(r2?.location, 8)
    }

    func testMultiCursorUtilitiesCaretMoveVertical() async throws {
        let text = "abc\n012345\nxyz\n"
        // caret at column 2 of line 2 (0-based) => '2'
        let ns = text as NSString
        let line2Start = ns.range(of: "012345").location
        let caret = line2Start + 2

        let up = MultiCursorUtilities.caretMovedVertically(text: text, caret: caret, direction: .up)
        XCTAssertEqual(up, 2)

        let down = MultiCursorUtilities.caretMovedVertically(text: text, caret: caret, direction: .down)
        let line3Start = ns.range(of: "xyz").location
        XCTAssertEqual(down, line3Start + 2)
    }

    func testEditorAIContextBuilderPrefersSelection() async throws {
        let buffer = "let a = 1\nlet b = 2\n"
        let ns = buffer as NSString
        let selection = ns.range(of: "let b = 2")
        let ctx = EditorAIContextBuilder.build(
            filePath: "/tmp/test.swift",
            language: "swift",
            buffer: buffer,
            selection: selection
        )

        XCTAssertTrue(ctx.contains("File: /tmp/test.swift"))
        XCTAssertTrue(ctx.contains("Language: swift"))
        XCTAssertTrue(ctx.contains("Selected Code:"))
        XCTAssertTrue(ctx.contains("let b = 2"))
        XCTAssertFalse(ctx.contains("Buffer:\n\n\(buffer)"))
    }

    func testCodeSelectionContext() async throws {
        let context = CodeSelectionContext()

        XCTAssertTrue(context.selectedText.isEmpty, "Selected text should be empty initially")
        XCTAssertNil(context.selectedRange, "Selected range should be nil initially")

        context.selectedText = "test selection"
        context.selectedRange = NSRange(location: 0, length: 13)

        XCTAssertEqual(context.selectedText, "test selection", "Selected text should be updated")
        XCTAssertEqual(context.selectedRange?.location, 0, "Selected range location should be set")
        XCTAssertEqual(context.selectedRange?.length, 13, "Selected range length should be set")
    }
}
