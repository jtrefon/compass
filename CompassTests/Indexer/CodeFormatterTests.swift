import XCTest

@testable import Compass

final class CodeFormatterTests: XCTestCase {
    private let indentationStyleKey = AppConstants.Storage.indentationStyleKey

    override func tearDown() {
        super.tearDown()
        AppRuntimeEnvironment.userDefaults.removeObject(forKey: indentationStyleKey)
    }

    func testBraceAnalyzerCountsBracesAndDetectsLeadingClosing() {
        let analyzer = BraceAnalyzer()

        let resultA = analyzer.analyze("} foo")
        XCTAssertTrue(resultA.startsWithClosing)
        XCTAssertEqual(resultA.closingCount, 1)
        XCTAssertEqual(resultA.openingCount, 0)

        let resultB = analyzer.analyze("func x() { return 1 }")
        XCTAssertFalse(resultB.startsWithClosing)
        XCTAssertEqual(resultB.openingCount, 2)
        XCTAssertEqual(resultB.closingCount, 2)
    }

    func testIndentLevelCalculatorDecrementsForLeadingClosingBrace() {
        let calculator = IndentLevelCalculator()
        let brace = BraceAnalysisResult(openingCount: 0, closingCount: 1, startsWithClosing: true)

        let transition = calculator.computeIndentTransition(currentIndentLevel: 2, braceResult: brace)
        XCTAssertEqual(transition.indentLevelForLine, 1)
        XCTAssertEqual(transition.nextIndentLevel, 1)
    }

    func testIndentLevelCalculatorIncrementsForMoreOpenThanClose() {
        let calculator = IndentLevelCalculator()
        let brace = BraceAnalysisResult(openingCount: 2, closingCount: 0, startsWithClosing: false)

        let transition = calculator.computeIndentTransition(currentIndentLevel: 1, braceResult: brace)
        XCTAssertEqual(transition.indentLevelForLine, 1)
        XCTAssertEqual(transition.nextIndentLevel, 3)
    }

    func testCodeFormatterFormatsUsingIndentationStyleTabs() {
        AppRuntimeEnvironment.userDefaults.set(IndentationStyle.tabs.rawValue, forKey: indentationStyleKey)

        let input = """
        func foo() {
        print(\"x\")
        }
        """

        let expected = """
        func foo() {
        \tprint(\"x\")
        }
        """

        let output = CodeFormatter.format(input, language: .swift)
        XCTAssertEqual(output, expected + "\n")
    }

    func testCodeFormatterPreservesBlankLines() {
        AppRuntimeEnvironment.userDefaults.set(IndentationStyle.tabs.rawValue, forKey: indentationStyleKey)

        let input = """
        func foo() {

        print(\"x\")
        }
        """

        let output = CodeFormatter.format(input, language: .swift)
        let lines = output.components(separatedBy: .newlines)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[1], "")
    }
}
