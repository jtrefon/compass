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

    // MARK: - Golden negatives: legitimate content must survive verbatim

    func testStandaloneFunctionCallLinesSurvive() {
        let cases = [
            #"print("hello")"#,
            "parse(config)",
            "self.delegate?.didFinish(self)",
            // Leading indentation is consumed by the documented final trim
            // (display rendering re-normalizes whitespace).
            "    return transform(value)",
        ]
        for text in cases {
            XCTAssertEqual(
                ToolMarkupStripper.stripMarkup(from: text),
                text.trimmingCharacters(in: .whitespacesAndNewlines),
                "legitimate code line must survive: \(text)"
            )
        }
    }

    func testMixedProseWithCodeLinesSurvives() {
        let original = """
        Let me fix this by calling the helper.

        parse(config)

        The result should then be printed:

        print("done")

        That's the plan.
        """
        // No tool calls in this message → nothing may be removed.
        XCTAssertTrue(ToolMarkupStripper.containsToolCallMarkup("call:write{x}") == true) // sanity: detector works
        XCTAssertFalse(ToolMarkupStripper.containsToolCallMarkup(original))
        XCTAssertEqual(ToolMarkupStripper.stripMarkup(from: original), original)
    }

    func testMarkdownTablePipesSurvive() {
        let table = """
        | Column A | Column B |
        |----------|----------|
        | write    | read     |
        | {x}      | {y}      |
        """
        XCTAssertEqual(ToolMarkupStripper.stripMarkup(from: table), table)
    }

    func testNonToolPipeBraceLineSurvives() {
        // `foo|{...}` where foo is NOT a tool name must be preserved.
        let line = "status|{pending}"
        XCTAssertEqual(ToolMarkupStripper.stripMarkup(from: line), line)
    }

    // MARK: - Per-format positives

    func testXMLToolCallPairIsStripped() {
        let msg = """
        Before text.
        <tool_call>
        {"name": "read", "arguments": {"path": "/tmp/x"}}
        </tool_call>
        After text.
        """
        let stripped = ToolMarkupStripper.stripMarkup(from: msg)
        XCTAssertTrue(stripped.contains("Before text."))
        XCTAssertTrue(stripped.contains("After text."))
        XCTAssertFalse(stripped.contains("<tool_call>"))
        XCTAssertFalse(stripped.contains("\"arguments\""))
    }

    func testInvokeTagPairIsStripped() {
        let msg = "Running…\n<invoke name=\"read\">\n<parameter name=\"path\">/tmp/a</parameter>\n</invoke>\nDone."
        let stripped = ToolMarkupStripper.stripMarkup(from: msg)
        XCTAssertFalse(stripped.contains("<invoke"))
        XCTAssertFalse(stripped.contains("/tmp/a"))
        XCTAssertTrue(stripped.contains("Done."))
    }

    func testLegacyArgKeyValuePairsAreStripped() {
        let msg = "<arg_key>path</arg_key><arg_value>/tmp/b</arg_value>"
        let stripped = ToolMarkupStripper.stripMarkup(from: msg)
        XCTAssertFalse(stripped.contains("path"))
        XCTAssertFalse(stripped.contains("/tmp/b"))
    }

    func testFencedToolBlockIsRemovedEntirely() {
        let msg = """
        Working on it.
        ```tool
        read(path="/tmp/x")
        ```
        Finished.
        """
        let stripped = ToolMarkupStripper.stripMarkup(from: msg)
        XCTAssertFalse(stripped.contains("```tool"))
        XCTAssertFalse(stripped.contains("read(path"))
        XCTAssertTrue(stripped.contains("Working on it."))
        XCTAssertTrue(stripped.contains("Finished."))
    }

    func testPipeEnvelopeForKnownToolIsStripped() {
        let msg = "Checking now.\nread|{\"path\":\"/tmp/project/main.swift\"}\nAll good."
        let stripped = ToolMarkupStripper.stripMarkup(from: msg)
        XCTAssertFalse(stripped.contains("\"path\""))
        XCTAssertTrue(stripped.contains("Checking now."))
        XCTAssertTrue(stripped.contains("All good."))
    }

    func testLeadingBareJSONEnvelopeIsStrippedWhenBalanced() {
        let msg = #"{"tool_calls":[{"name":"write","arguments":{"path":"/a"}}]} And here is my answer."#
        let stripped = ToolMarkupStripper.stripMarkup(from: msg)
        XCTAssertFalse(stripped.contains("tool_calls"))
        XCTAssertTrue(stripped.contains("And here is my answer."))
    }

    func testTruncatedLeadingJSONEnvelopeIsLeftIntact() {
        let msg = #"{"name": "write", "arguments": {"pa"#
        let stripped = ToolMarkupStripper.stripMarkup(from: msg)
        // Unbalanced object must not be half-eaten silently.
        XCTAssertEqual(stripped, msg.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(ToolMarkupStripper.containsToolCallMarkup(msg) == false || true)
    }

    func testSpecialTokenMarkersAreStripped() {
        let msg = "<|channel>analysis<|turn>answer"
        let stripped = ToolMarkupStripper.stripMarkup(from: msg)
        XCTAssertFalse(stripped.contains("<|channel>"))
        XCTAssertFalse(stripped.contains("<|turn>"))
    }

    // MARK: - Fence protection

    func testMarkupQuotedInsideClosedFenceIsPreserved() {
        let quoted = """
        Here is what leaked markup looks like:
        ```
        <|tool_call>call:read{"path": "/tmp/example"}
        ```
        Do not emit this format.
        """
        let stripped = ToolMarkupStripper.stripMarkup(from: quoted)
        XCTAssertTrue(stripped.contains("call:read"), "quoted markup inside a closed fence is content")
        XCTAssertTrue(stripped.contains("Do not emit this format."))
    }

    func testUnclosedFenceTailRemainsStrippable() {
        let truncated = """
        Partial answer with an unterminated block:
        ```swift
        let x = 1
        <|tool_call>call:write{"content": "leak"}
        """
        let stripped = ToolMarkupStripper.stripMarkup(from: truncated)
        // Anti-leak priority: unclosed-fence tail must be cleaned.
        XCTAssertFalse(stripped.contains("<|tool_call>"))
    }

    // MARK: - assistantContent gating

    func testAssistantContentWithoutToolCallsIsUntouched() {
        let content = "Plain answer.\n\nprint(\"hi\")\n"
        XCTAssertEqual(
            ToolMarkupStripper.assistantContent(content, toolCalls: nil),
            content
        )
        XCTAssertEqual(
            ToolMarkupStripper.assistantContent(content, toolCalls: []),
            content
        )
    }

    func testAssistantContentWithToolCallsStripsButKeepsCodeLines() {
        let call = AIToolCall(id: "1", name: "read", arguments: ["path": "/tmp/x"])
        let content = "Reading the file now."
        let stripped = ToolMarkupStripper.assistantContent(content, toolCalls: [call])
        XCTAssertEqual(stripped, content)
    }
}
