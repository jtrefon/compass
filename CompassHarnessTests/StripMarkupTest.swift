import XCTest
@testable import Compass

final class StripMarkupTest: XCTestCase {
    func testStripToolCallBlock() {
        let input = """
        <tool_call>
        <search>
        <args>
        <path>wp-content/plugins</path>
        </args>
        </search>
        </tool_call>
        Let me review the plugin.
        """
        let output = ToolMarkupStripper.stripMarkup(from: input)
        print("[TEST] input='\(input)'")
        print("[TEST] output='\(output)'")
        print("[TEST] contains tool_call=\(output.contains("tool_call"))")
        XCTAssertFalse(output.contains("tool_call"), "stripMarkup should remove tool_call tags")
    }

    func testStripBareToolCall() {
        let input = "<tool_call>\nSome text"
        let output = ToolMarkupStripper.stripMarkup(from: input)
        print("[TEST] bare input='\(input)'")
        print("[TEST] bare output='\(output)'")
        XCTAssertFalse(output.contains("tool_call"), "Bare <tool_call> should be stripped")
    }
}