import XCTest
import Foundation
@testable import Compass

@MainActor
final class LineNumberRulerViewTests: XCTestCase {

    func testStartingLineNumberCountsLinesUpToFirstCharIndex() async throws {
        let sampleString = "a\nb\nc\n" as NSString

        XCTAssertEqual(ModernLineNumberRulerView.startingLineNumber(string: sampleString, firstCharIndex: 0), 1)
        XCTAssertEqual(ModernLineNumberRulerView.startingLineNumber(string: sampleString, firstCharIndex: 1), 1)
        XCTAssertEqual(ModernLineNumberRulerView.startingLineNumber(string: sampleString, firstCharIndex: 2), 2)
        XCTAssertEqual(ModernLineNumberRulerView.startingLineNumber(string: sampleString, firstCharIndex: 4), 3)
    }
}
