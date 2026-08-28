import XCTest
import Foundation
@testable import Compass

final class SymbolExtractorTests: XCTestCase {

    func testSwiftClass() {
        let code = """
        public final class AuthService {
            private let apiKey: String
            func validateUser(token: String) -> Bool {
                return true
            }
        }
        """
        let url = URL(fileURLWithPath: "/project/Sources/Auth/AuthService.swift")
        let symbols = SymbolExtractor.extract(from: url, content: code)
        XCTAssertEqual(symbols.count, 3)
        XCTAssertEqual(symbols[0].name, "AuthService")
        XCTAssertEqual(symbols[0].kind, "class")
        XCTAssertEqual(symbols[0].scope, "public")
        XCTAssertEqual(symbols[0].parentName, "")
        XCTAssertEqual(symbols[1].name, "apiKey")
        XCTAssertEqual(symbols[1].kind, "property")
        XCTAssertEqual(symbols[1].scope, "private")
        XCTAssertEqual(symbols[1].parentName, "AuthService")
        XCTAssertEqual(symbols[2].name, "validateUser")
        XCTAssertEqual(symbols[2].kind, "method")
        XCTAssertEqual(symbols[2].scope, "")
        XCTAssertEqual(symbols[2].parentName, "AuthService")
    }

    func testSwiftStruct() {
        let code = """
        struct Config {
            let timeout: Int
        }
        """
        let url = URL(fileURLWithPath: "/project/Sources/Config.swift")
        let symbols = SymbolExtractor.extract(from: url, content: code)
        XCTAssertEqual(symbols.count, 2)
        XCTAssertEqual(symbols[0].name, "Config")
        XCTAssertEqual(symbols[0].kind, "struct")
        XCTAssertEqual(symbols[1].name, "timeout")
        XCTAssertEqual(symbols[1].kind, "property")
    }

    func testSwiftEnum() {
        let code = "enum HTTPMethod { case get, post }"
        let url = URL(fileURLWithPath: "/project/Sources/HTTP.swift")
        let symbols = SymbolExtractor.extract(from: url, content: code)
        XCTAssertEqual(symbols.count, 1)
        XCTAssertEqual(symbols[0].name, "HTTPMethod")
        XCTAssertEqual(symbols[0].kind, "enum")
    }

    func testSwiftExtension() {
        let code = "extension String { var trimmed: String { self } }"
        let url = URL(fileURLWithPath: "/project/Sources/Extensions.swift")
        let symbols = SymbolExtractor.extract(from: url, content: code)
        XCTAssertGreaterThanOrEqual(symbols.count, 1)
        XCTAssertEqual(symbols[0].kind, "extension")
    }

    func testSwiftSignature() {
        let code = "func fetchUser(id: Int) async throws -> User?"
        let url = URL(fileURLWithPath: "/project/Sources/UserService.swift")
        let symbols = SymbolExtractor.extract(from: url, content: code)
        XCTAssertEqual(symbols.count, 1)
        XCTAssertEqual(symbols[0].name, "fetchUser")
        XCTAssertEqual(symbols[0].kind, "method")
        XCTAssertTrue(symbols[0].signature.contains("->"))
    }

    func testSwiftTypealias() {
        let code = "typealias CompletionHandler = (Result<User, Error>) -> Void"
        let url = URL(fileURLWithPath: "/project/Sources/Types.swift")
        let symbols = SymbolExtractor.extract(from: url, content: code)
        XCTAssertEqual(symbols.count, 1)
        XCTAssertEqual(symbols[0].kind, "typealias")
        XCTAssertEqual(symbols[0].name, "CompletionHandler")
    }

    func testJavaScriptClass() {
        let code = """
        export class UserService {
            constructor() {}
            async getUser(id) {}
        }
        """
        let url = URL(fileURLWithPath: "/project/src/UserService.js")
        let symbols = SymbolExtractor.extract(from: url, content: code)
        XCTAssertGreaterThanOrEqual(symbols.count, 1)
        XCTAssertEqual(symbols[0].kind, "class")
        XCTAssertEqual(symbols[0].name, "UserService")
    }

    func testJavaScriptFunction() {
        let code = "export function formatDate(date) { return '' }"
        let url = URL(fileURLWithPath: "/project/src/dateUtils.js")
        let symbols = SymbolExtractor.extract(from: url, content: code)
        XCTAssertEqual(symbols.count, 1)
        XCTAssertEqual(symbols[0].kind, "function")
        XCTAssertEqual(symbols[0].name, "formatDate")
        XCTAssertEqual(symbols[0].scope, "export")
    }

    func testPythonClass() {
        let code = """
        class UserService:
            def get_user(self, id):
                pass
        """
        let url = URL(fileURLWithPath: "/project/src/user_service.py")
        let symbols = SymbolExtractor.extract(from: url, content: code)
        XCTAssertEqual(symbols.count, 2)
        XCTAssertEqual(symbols[0].name, "UserService")
        XCTAssertEqual(symbols[0].kind, "class")
        XCTAssertEqual(symbols[1].name, "get_user")
        XCTAssertEqual(symbols[1].kind, "method")
        XCTAssertEqual(symbols[1].parentName, "UserService")
    }

    func testPythonFunction() {
        let code = "def validate_email(email): pass"
        let url = URL(fileURLWithPath: "/project/src/validation.py")
        let symbols = SymbolExtractor.extract(from: url, content: code)
        XCTAssertEqual(symbols.count, 1)
        XCTAssertEqual(symbols[0].kind, "function")
        XCTAssertEqual(symbols[0].name, "validate_email")
    }

    func testUnsupportedLanguage() {
        let code = "<?php echo 'hello'; ?>"
        let url = URL(fileURLWithPath: "/project/index.php")
        let symbols = SymbolExtractor.extract(from: url, content: code)
        XCTAssertTrue(symbols.isEmpty)
    }
}
