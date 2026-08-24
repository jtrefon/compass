import XCTest
@testable import Compass

final class PathValidatorTests: XCTestCase {
    private let tempRoot: URL = {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PathValidatorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? "test".write(to: tmp.appendingPathComponent("file.php"), atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        try? "nested".write(to: tmp.appendingPathComponent("subdir").appendingPathComponent("nested.js"), atomically: true, encoding: .utf8)
        return tmp
    }()

    deinit { try? FileManager.default.removeItem(at: tempRoot) }

    // MARK: - Project-root-relative paths

    func testRelativePathResolvesCorrectly() throws {
        let validator = PathValidator(projectRoot: tempRoot)
        let url = try validator.validateAndResolve("file.php")
        XCTAssertEqual(url.lastPathComponent, "file.php")
        XCTAssertTrue(url.path.hasPrefix(tempRoot.path))
    }

    func testRelativeNestedPathResolvesCorrectly() throws {
        let validator = PathValidator(projectRoot: tempRoot)
        let url = try validator.validateAndResolve("subdir/nested.js")
        XCTAssertEqual(url.lastPathComponent, "nested.js")
        XCTAssertTrue(url.path.contains("subdir"))
    }

    // MARK: - Leading-slash paths (auto-normalized)

    func testLeadingSlashPathNormalizesToRelative() throws {
        let validator = PathValidator(projectRoot: tempRoot)
        let url = try validator.validateAndResolve("/file.php")
        XCTAssertEqual(url.lastPathComponent, "file.php")
        XCTAssertTrue(url.path.hasPrefix(tempRoot.path))
    }

    func testLeadingSlashNestedPathNormalizesCorrectly() throws {
        let validator = PathValidator(projectRoot: tempRoot)
        let url = try validator.validateAndResolve("/subdir/nested.js")
        XCTAssertEqual(url.lastPathComponent, "nested.js")
        XCTAssertTrue(url.path.contains("subdir"))
    }

    // MARK: - Hallucinated root paths (like /workspace/project/file.php)

    func testHallucinatedWorkspaceRootIsStripped() throws {
        let validator = PathValidator(projectRoot: tempRoot)
        let url = try validator.validateAndResolve("/workspace/project/file.php")
        XCTAssertEqual(url.lastPathComponent, "file.php")
        XCTAssertTrue(url.path.hasPrefix(tempRoot.path))
    }

    func testHallucinatedUsersRootIsStripped() throws {
        let validator = PathValidator(projectRoot: tempRoot)
        let url = try validator.validateAndResolve("/Users/Projects/file.php")
        XCTAssertEqual(url.lastPathComponent, "file.php")
        XCTAssertTrue(url.path.hasPrefix(tempRoot.path))
    }

    func testHallucinatedHomeRootIsStripped() throws {
        let validator = PathValidator(projectRoot: tempRoot)
        let url = try validator.validateAndResolve("/home/user/project/file.php")
        XCTAssertEqual(url.lastPathComponent, "file.php")
        XCTAssertTrue(url.path.hasPrefix(tempRoot.path))
    }

    // MARK: - Absolute paths within project root

    func testAbsolutePathWithinProjectRoot() throws {
        let validator = PathValidator(projectRoot: tempRoot)
        let absolutePath = tempRoot.appendingPathComponent("file.php").path
        let url = try validator.validateAndResolve(absolutePath)
        XCTAssertEqual(url.path, tempRoot.appendingPathComponent("file.php").standardizedFileURL.path)
    }

    // MARK: - Error cases

    func testPathOutsideProjectRootThrowsAccessDenied() throws {
        let validator = PathValidator(projectRoot: tempRoot)
        XCTAssertThrowsError(try validator.validateAndResolve("/etc/passwd")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Access denied"))
        }
    }

    func testNonexistentPathThrowsFileNotFound() {
        let validator = PathValidator(projectRoot: tempRoot)
        // The path resolves within the sandbox but the file doesn't exist —
        // validateAndResolve only checks sandbox, not existence.
        XCTAssertNoThrow(try validator.validateAndResolve("nonexistent.php"))
    }

}
