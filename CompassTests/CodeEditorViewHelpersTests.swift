import XCTest
@testable import Compass

@MainActor
final class CodeEditorViewHelpersTests: XCTestCase {

    func testApplyWordWrapEnablesWidthTrackingAndHidesHorizontalScroller() {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = true

        let textView = NSTextView()
        // Ensure there is a text container.
        _ = textView.textContainer

        TextViewRepresentable.applyWordWrap(true, to: scrollView, textView: textView)

        XCTAssertEqual(textView.isHorizontallyResizable, false)
        XCTAssertEqual(textView.textContainer?.widthTracksTextView, true)
        XCTAssertEqual(scrollView.hasHorizontalScroller, false)
    }

    func testApplyWordWrapDisablesWidthTrackingAndShowsHorizontalScroller() {
        let scrollView = NSScrollView()
        scrollView.hasHorizontalScroller = false

        let textView = NSTextView()
        _ = textView.textContainer

        TextViewRepresentable.applyWordWrap(false, to: scrollView, textView: textView)

        XCTAssertEqual(textView.isHorizontallyResizable, true)
        XCTAssertEqual(textView.textContainer?.widthTracksTextView, false)
        XCTAssertEqual(scrollView.hasHorizontalScroller, true)
    }

    func testResolveEditorFontFallsBackToMonospacedFontWhenFamilyUnavailable() {
        let font = TextViewRepresentable.resolveEditorFont(fontFamily: "__font_family_does_not_exist__", fontSize: 13)
        XCTAssertGreaterThan(font.pointSize, 0)
    }
}
