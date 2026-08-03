import XCTest
@testable import Compass

final class ToolMarkupStripperTests: XCTestCase {

    /// The exact Gemma `call:write` payload that was committed as raw markup —
    /// content contains unbalanced-ish PHP braces and a multi-line string.
    func testGemmaWriteMarkupIsStripped() {
        let msg = """
        <|tool_call>call:write{content:<|"|><?php
        class Career_Register_Admin {
            public function __construct() {
                add_action( 'admin_menu', array( $this, 'register_admin_menu' ) );
            }
            private function register_admin_menu() {
                if ( ! defined( 'ABSPATH' ) ) {
                    exit;
                }
            }
        }
        <|"|>,path:<|"|>wp-content/plugins/career-register/includes/class-career-register-admin.php<|"|>}
        """

        let stripped = ToolMarkupStripper.stripMarkup(from: msg)

        XCTAssertFalse(stripped.contains("call:write"), "call:write must be stripped")
        XCTAssertFalse(stripped.contains("<|tool_call>"), "Gemma wrapper must be stripped")
        XCTAssertFalse(stripped.contains("<|\"|>"), "Gemma string delimiters must be stripped")
    }

    /// The truncated `call:search` from the session (no closing brace) must
    /// not leave markup behind either.
    func testGemmaSearchMarkupIsStripped() {
        let msg = "<|tool_call>call:search{path:<|\"|>wp-content/plugins/career-register/includes<|\"|>}"
        let stripped = ToolMarkupStripper.stripMarkup(from: msg)
        XCTAssertFalse(stripped.contains("call:search"))
        XCTAssertFalse(stripped.contains("<|tool_call>"))
    }

    /// Plain text passes through untouched.
    func testPlainTextUnaffected() {
        let text = "The plugin is 60% production ready."
        XCTAssertEqual(ToolMarkupStripper.stripMarkup(from: text), text)
    }
}
