import XCTest
@testable import Compass

/// Pins the Rule 6 invariant: JSON round-tripping produces Double/Int/Int64/
/// NSNumber/String shapes for the same logical value — coercion must accept
/// all of them. These values feed mutation tools (`edit` line numbers,
/// `replace_all`) directly.
final class ToolArgumentCoercionTests: XCTestCase {

    // MARK: - asDouble

    func testAsDoubleAcceptsEveryNumericShape() {
        XCTAssertEqual(ToolArgumentCoercion.asDouble(1.5), 1.5)          // Double
        XCTAssertEqual(ToolArgumentCoercion.asDouble(3), 3.0)            // Int
        XCTAssertEqual(ToolArgumentCoercion.asDouble(Int32(7)), 7.0)     // Int32
        XCTAssertEqual(ToolArgumentCoercion.asDouble(Int64(9)), 9.0)     // Int64
        XCTAssertEqual(ToolArgumentCoercion.asDouble(NSNumber(value: 2.5)), 2.5)
        XCTAssertEqual(ToolArgumentCoercion.asDouble("2.5"), 2.5)        // String
    }

    func testAsDoubleRejectsNonNumeric() {
        XCTAssertNil(ToolArgumentCoercion.asDouble(nil))
        XCTAssertNil(ToolArgumentCoercion.asDouble("not-a-number"))
    }

    /// JSON round-trip equivalence: the same wire value decoded by different
    /// parsers must coerce to the same Double.
    func testAsDoubleRoundTripEquivalence() {
        let shapes: [Any?] = [42, Int64(42), NSNumber(value: 42), "42"]
        for shape in shapes {
            XCTAssertEqual(ToolArgumentCoercion.asDouble(shape), 42.0)
        }
    }

    // MARK: - asBool

    func testAsBoolLiteralBooleans() {
        XCTAssertEqual(ToolArgumentCoercion.asBool(true), true)
        XCTAssertEqual(ToolArgumentCoercion.asBool(false), false)
    }

    func testAsBoolStringVariants() {
        XCTAssertTrue(ToolArgumentCoercion.asBool("1") == true)
        XCTAssertTrue(ToolArgumentCoercion.asBool("true") == true)
        XCTAssertTrue(ToolArgumentCoercion.asBool("YES") == true)
        XCTAssertTrue(ToolArgumentCoercion.asBool(" True ") == true)   // trimmed + case-insensitive
        XCTAssertTrue(ToolArgumentCoercion.asBool("0") == false)
        XCTAssertTrue(ToolArgumentCoercion.asBool("false") == false)
        XCTAssertTrue(ToolArgumentCoercion.asBool("No") == false)
    }

    func testAsBoolRejectsAmbiguousStrings() {
        XCTAssertNil(ToolArgumentCoercion.asBool("maybe"))
        XCTAssertNil(ToolArgumentCoercion.asBool(""))
        XCTAssertNil(ToolArgumentCoercion.asBool(nil))
    }

    func testAsBoolNumericStringsAreNotBools() {
        // "2" is not a documented boolean spelling — reject rather than guess.
        XCTAssertNil(ToolArgumentCoercion.asBool("2"))
    }
}
