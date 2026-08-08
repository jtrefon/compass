import XCTest
@testable import Compass

final class ParserRegistryTests: XCTestCase {

    func testDefaultRegistryHasAllParsers() {
        let r = ParserRegistry.default()
        XCTAssertNotNil(r.parser(for: "json"))
        XCTAssertNotNil(r.parser(for: "xml"))
        XCTAssertNotNil(r.parser(for: "legacy_tool_code"))
        XCTAssertNotNil(r.parser(for: "bare_function"))
        XCTAssertNotNil(r.parser(for: "tool_call_block"))
        XCTAssertNotNil(r.parser(for: "minimax_m2"))
        XCTAssertNotNil(r.parser(for: "gemma"))
    }

    func testRegisterAndUnregister() {
        let r = ParserRegistry()
        let p = JSONToolCallFormatParser()
        XCTAssertNil(r.parser(for: "json"))
        r.register(p)
        XCTAssertNotNil(r.parser(for: "json"))
        r.unregister(p)
        XCTAssertNil(r.parser(for: "json"))
    }
}

// MARK: - JSON parser

final class JSONToolCallFormatParserTests: XCTestCase {
    func testSingleObject() {
        let p = JSONToolCallFormatParser()
        let (calls, remaining) = p.parse(#"{"name":"read_file","arguments":{"path":"/f"}}"#)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read")
        XCTAssertTrue(calls[0].arguments.contains("path"))
        XCTAssertEqual(remaining, "")
    }

    func testEnvelope() {
        let p = JSONToolCallFormatParser()
        let json = #"{"tool_calls":[{"name":"read_file","arguments":{"path":"/a"}},{"name":"list_files"}]}"#
        let (calls, remaining) = p.parse(json)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].name, "read")
        XCTAssertEqual(calls[1].name, "search")
    }

    func testFencedJSON() {
        let p = JSONToolCallFormatParser()
        let text = "some text\n```json\n{\"name\":\"read_file\",\"arguments\":{\"path\":\"/f\"}}\n```\nmore text"
        let (calls, remaining) = p.parse(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read")
        XCTAssertTrue(remaining.contains("some text"))
        XCTAssertTrue(remaining.contains("more text"))
    }

    func testNonJSONReturnsEmpty() {
        let p = JSONToolCallFormatParser()
        let (calls, remaining) = p.parse("plain text")
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(remaining, "plain text")
    }
}

// MARK: - XML parser

final class XMLToolCallFormatParserTests: XCTestCase {
    func testStandardXML() {
        let p = XMLToolCallFormatParser()
        let xml = "<tool_call><tool name=\"read_file\"><arg name=\"path\">/f</arg></tool></tool_call>"
        let (calls, remaining) = p.parse(xml)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read")
        XCTAssertTrue(calls[0].arguments.contains("path"))
    }

    func testTextOutsideXMLIsRemaining() {
        let p = XMLToolCallFormatParser()
        let xml = "before<tool_call><tool name=\"read_file\"><arg name=\"path\">/f</arg></tool></tool_call>after"
        let (calls, remaining) = p.parse(xml)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(remaining, "after")
    }
}

// MARK: - Legacy Tool Code parser

final class LegacyToolCodeFormatParserTests: XCTestCase {
    func testLegacyToolCode() {
        let p = LegacyToolCodeFormatParser()
        let code = "<tool_code>read_file<param name=\"path\">/f</param></tool_code>"
        let (calls, remaining) = p.parse(code)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read")
    }
}

// MARK: - Bare Function parser

final class BareFunctionFormatParserTests: XCTestCase {
    func testBareFunction() {
        let p = BareFunctionFormatParser()
        let text = "<function=read_file><parameter=path>/f</parameter></function>"
        let (calls, _) = p.parse(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read")
    }
}

// MARK: - Tool Call Block parser

final class ToolCallBlockFormatParserTests: XCTestCase {
    func testBlockParsesWriteFile() {
        let p = ToolCallBlockFormatParser()
        let block = "<tool_call>\n/src/main.js\nconsole.log(1)\n</tool_call>"
        let (calls, _) = p.parse(block)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "write")
        XCTAssertTrue(calls[0].arguments.contains("path"))
        XCTAssertTrue(calls[0].arguments.contains("content"))
    }
}

// MARK: - MiniMax parser

final class MinimaxFormatParserTests: XCTestCase {
    func testMinimaxInvoke() {
        let p = MinimaxFormatParser()
        let text = "<invoke name=\"run_command\"><parameter name=\"command\">ls</parameter></invoke>"
        let (calls, _) = p.parse(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "bash")
        XCTAssertTrue(calls[0].arguments.contains("command"))
    }
}

// MARK: - Gemma parser

final class GemmaFormatParserTests: XCTestCase {
    func testGemmaCall() {
        let p = GemmaFormatParser()
        let text = "call:read_file{path:/f}"
        let (calls, _) = p.parse(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read")
    }

    func testGemmaCallWithStringDelimiter() {
        let p = GemmaFormatParser()
        let text = "call:write_file{path:<|\"|>/path/file<|\"|>,content:<|\"|>hello<|\"|>}"
        let (calls, _) = p.parse(text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "write")
    }
}
