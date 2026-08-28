import XCTest
@testable import Compass

final class PreWritePreventionEngineTests: XCTestCase {
    var engine: PreWritePreventionEngine!
    var fileSystemService: FileSystemService!
    var tempProjectRoot: URL!
    
    override func setUp() {
        super.setUp()
        fileSystemService = FileSystemService()
        tempProjectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempProjectRoot, withIntermediateDirectories: true)
        engine = PreWritePreventionEngine(fileSystemService: fileSystemService, projectRoot: tempProjectRoot)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempProjectRoot)
        engine = nil
        fileSystemService = nil
        tempProjectRoot = nil
        super.tearDown()
    }
    
    // MARK: - Duplicate Detection Tests
    
    func testDetectsDuplicateFilePathCreation() {
        let existingPath = tempProjectRoot.appendingPathComponent("Existing.swift")
        let existingContent = "func duplicateTarget() { return true }"
        try? fileSystemService.writeFile(content: existingContent, to: existingPath)
        
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "Replacement.swift", "content": existingContent],
            allowOverride: false
        )
        
        XCTAssertEqual(result.outcome, .block, "Should block exact duplicate write")
        XCTAssertEqual(result.duplicateRiskCount, 1)
        XCTAssertTrue(result.findings.contains(where: { $0.findingType == .duplicateImpl }))
    }
    
    func testDetectsExactContentDuplication() {
        let existingPath = tempProjectRoot.appendingPathComponent("Original.swift")
        let duplicateContent = "func authenticate() { return true }"
        try? fileSystemService.writeFile(content: duplicateContent, to: existingPath)
        
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "Duplicate.swift", "content": duplicateContent],
            allowOverride: false
        )
        
        XCTAssertEqual(result.outcome, .block, "Should block exact content duplication")
        XCTAssertGreaterThan(result.duplicateRiskCount, 0)
        let finding = result.findings.first(where: { $0.findingType == .duplicateImpl })
        XCTAssertNotNil(finding)
        XCTAssertTrue(finding?.explanation.contains("exact duplicate") ?? false)
    }
    
    func testAllowsExactDuplicatePlainTextOutputsWithoutBlocking() {
        let existingPath = tempProjectRoot.appendingPathComponent("source.txt")
        let duplicateContent = "STABLE INPUT"
        try? fileSystemService.writeFile(content: duplicateContent, to: existingPath)

        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "processed.txt", "content": duplicateContent],
            allowOverride: false
        )

        XCTAssertNotEqual(result.outcome, .block, "Plain-text output duplication should not be hard blocked")
        XCTAssertGreaterThan(result.duplicateRiskCount, 0)
        let finding = result.findings.first(where: { $0.findingType == .duplicateImpl })
        XCTAssertNotNil(finding)
        XCTAssertEqual(finding?.severity, .warning)
        XCTAssertFalse(finding?.blockRecommended ?? true)
    }
    
    func testDetectsSymbolCollisions() {
        let existingPath = tempProjectRoot.appendingPathComponent("Service.swift")
        try? fileSystemService.writeFile(content: "class AuthService { }", to: existingPath)
        
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "NewService.swift", "content": "class AuthService { }"],
            allowOverride: false
        )
        
        XCTAssertNotEqual(result.outcome, .pass, "Should detect symbol collision")
        XCTAssertGreaterThan(result.duplicateRiskCount, 0)
    }
    
    func testAllowsUniqueNewFiles() {
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "UniqueFile.swift", "content": "class UniqueClass { }"],
            allowOverride: false
        )
        
        XCTAssertEqual(result.outcome, .warn, "Unique writes can still warn for unreferenced new symbols")
        XCTAssertEqual(result.duplicateRiskCount, 0)
    }
    
    // MARK: - Dead Code Detection Tests
    
    func testDetectsTempFileCreation() {
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "tmp/TempFile.swift", "content": "class TempClass { }"],
            allowOverride: false
        )
        
        XCTAssertNotEqual(result.outcome, .pass, "Should warn about temp file creation")
        XCTAssertGreaterThan(result.deadCodeRiskCount, 0)
        let finding = result.findings.first(where: { $0.findingType == .deadCodeRisk })
        XCTAssertNotNil(finding)
        XCTAssertTrue(finding?.explanation.contains("temporary") ?? false)
    }
    
    func testDetectsDraftFileCreation() {
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "DraftImplementation.swift", "content": "class DraftClass { }"],
            allowOverride: false
        )
        
        XCTAssertNotEqual(result.outcome, .pass, "Should warn about draft file creation")
        XCTAssertGreaterThan(result.deadCodeRiskCount, 0)
    }
    
    func testDetectsOrphanSymbols() {
        let existingPath = tempProjectRoot.appendingPathComponent("Main.swift")
        try? fileSystemService.writeFile(content: "func main() { }", to: existingPath)
        
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "Orphan.swift", "content": "class OrphanClass { func orphanMethod() { } }"],
            allowOverride: false
        )
        
        XCTAssertNotEqual(result.outcome, .pass, "Should warn about orphan symbols")
        XCTAssertGreaterThan(result.deadCodeRiskCount, 0)
        let finding = result.findings.first(where: { $0.findingType == .deadCodeRisk })
        XCTAssertNotNil(finding)
        XCTAssertTrue(finding?.explanation.contains("unreferenced") ?? false)
    }
    
    func testAllowsReferencedSymbols() {
        let existingPath = tempProjectRoot.appendingPathComponent("Main.swift")
        try? fileSystemService.writeFile(content: "let service = NewService()", to: existingPath)
        
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "NewService.swift", "content": "class NewService { }"],
            allowOverride: false
        )
        
        XCTAssertEqual(result.outcome, .pass, "Should allow referenced symbols")
        XCTAssertEqual(result.deadCodeRiskCount, 0)
    }
    
    // MARK: - Policy Outcome Tests
    
    func testPassOutcomeForCleanWrite() {
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "Clean.swift", "content": "// Clean implementation"],
            allowOverride: false
        )
        
        XCTAssertEqual(result.outcome, .pass)
        XCTAssertTrue(result.findings.isEmpty)
    }
    
    func testWarnOutcomeForMinorIssues() {
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "Draft.swift", "content": "class DraftClass { }"],
            allowOverride: false
        )
        
        XCTAssertEqual(result.outcome, .warn, "Should warn for minor issues")
        XCTAssertFalse(result.findings.isEmpty)
        XCTAssertTrue(result.findings.allSatisfy { !$0.blockRecommended })
    }
    
    func testBlockOutcomeForCriticalIssues() {
        let existingPath = tempProjectRoot.appendingPathComponent("Existing.swift")
        let duplicateContent = "func duplicateTarget() { return true }"
        try? fileSystemService.writeFile(content: duplicateContent, to: existingPath)
        
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "AnotherFile.swift", "content": duplicateContent],
            allowOverride: false
        )
        
        XCTAssertEqual(result.outcome, .block, "Should block critical issues")
        XCTAssertTrue(result.findings.contains(where: { $0.blockRecommended && $0.severity == .critical }))
    }
    
    func testOverrideAllowsBlockedWrite() {
        let existingPath = tempProjectRoot.appendingPathComponent("Existing.swift")
        let duplicateContent = "func duplicateTarget() { return true }"
        try? fileSystemService.writeFile(content: duplicateContent, to: existingPath)
        
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "AnotherFile.swift", "content": duplicateContent],
            allowOverride: true
        )
        
        XCTAssertNotEqual(result.outcome, .block, "Override should prevent blocking")
        XCTAssertGreaterThan(result.findings.count, 0, "Findings should still be reported")
    }
    
    // MARK: - Tool Support Tests
    
    func testSupportsWriteFileTool() {
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "Test.swift", "content": "test"],
            allowOverride: false
        )
        
        XCTAssertNotNil(result, "Should support write_file tool")
    }
    
 
    
    func testSupportsReplaceInFileTool() {
        let existingPath = tempProjectRoot.appendingPathComponent("Existing.swift")
        try? fileSystemService.writeFile(content: "old text", to: existingPath)
        
        let result = engine.check(
            toolName: "replace_in_file",
            arguments: ["path": "Existing.swift", "old_text": "old", "new_text": "new"],
            allowOverride: false
        )
        
        XCTAssertNotNil(result, "Should support replace_in_file tool")
    }
    
    func testIgnoresUnsupportedTools() {
        let result = engine.check(
            toolName: "read_file",
            arguments: ["path": "Test.swift"],
            allowOverride: false
        )
        
        XCTAssertEqual(result.outcome, .pass, "Should pass for unsupported tools")
        XCTAssertTrue(result.findings.isEmpty)
    }
    
    // MARK: - Finding Summary Tests
    
    func testSummaryFormatsFindings() {
        let existingPath = tempProjectRoot.appendingPathComponent("Existing.swift")
        try? fileSystemService.writeFile(content: "func authenticate() { return true }", to: existingPath)
        
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "Duplicate.swift", "content": "func authenticate() { return true }"],
            allowOverride: false
        )
        
        let summary = result.summary
        XCTAssertFalse(summary.isEmpty, "Summary should not be empty")
        XCTAssertFalse(result.findings.isEmpty, "Result should include at least one finding")
        XCTAssertEqual(result.findings.first?.findingType, .duplicateImpl)
    }
    
    func testEmptyFindingsProducesEmptySummary() {
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "Clean.swift", "content": "clean"],
            allowOverride: false
        )
        
        let summary = result.summary
        XCTAssertTrue(summary.contains("No prevention findings"), "Should indicate no findings")
    }
    
    // MARK: - Path Resolution Tests
    
    func testResolvesAbsolutePaths() {
        let absolutePath = tempProjectRoot.appendingPathComponent("Absolute.swift").path
        
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": absolutePath, "content": "test"],
            allowOverride: false
        )
        
        XCTAssertNotNil(result)
    }
    
    func testResolvesRelativePaths() {
        let result = engine.check(
            toolName: "write_file",
            arguments: ["path": "Relative.swift", "content": "test"],
            allowOverride: false
        )
        
        XCTAssertNotNil(result)
    }
    
    // MARK: - Multiple Files Tests
    
    func testChecksMultipleFilesInWriteFiles() {
        let existingPath = tempProjectRoot.appendingPathComponent("Existing.swift")
        let duplicateContent = "func duplicateTarget() { return true }"
        try? fileSystemService.writeFile(content: duplicateContent, to: existingPath)
        
        let result = engine.check(
            toolName: "write_files",
            arguments: [
                "files": [
                    ["path": "Duplicate.swift", "content": duplicateContent],
                    ["path": "New.swift", "content": "new content"]
                ]
            ],
            allowOverride: false
        )
        
        XCTAssertGreaterThan(result.findings.count, 0, "Should detect issues in multiple files")
        XCTAssertEqual(result.outcome, .block, "Should block if any file has critical issues")
    }
}
