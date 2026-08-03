import XCTest
@testable import Compass

final class AppLaunchContextTests: XCTestCase {
    func testDetect_AppMode_WhenNoXCTestEnvironment() {
        let context = AppLaunchContext.detect(environmentOverride: [:])

        XCTAssertEqual(context.mode, .app)
        XCTAssertFalse(context.isTesting)
        XCTAssertFalse(context.isUITesting)
        XCTAssertFalse(context.disableHeavyInit)
    }

    func testDetect_UnitTestMode_WhenXCTestWithoutXCUIFlag() {
        let context = AppLaunchContext.detect(
            environmentOverride: ["XCTestConfigurationFilePath": "/tmp/test.xcconfig"]
        )

        XCTAssertEqual(context.mode, .unitTest)
        XCTAssertTrue(context.isTesting)
        XCTAssertFalse(context.isUITesting)
    }

    func testDetect_UITestMode_WhenXCUIFlagPresent() {
        let context = AppLaunchContext.detect(
            environmentOverride: [
                TestLaunchKeys.xcuiTesting: "1",
                TestLaunchKeys.testProfileDir: "/tmp/profile",
                TestLaunchKeys.disableHeavyInit: "1"
            ]
        )

        XCTAssertEqual(context.mode, .uiTest)
        XCTAssertTrue(context.isTesting)
        XCTAssertTrue(context.isUITesting)
        XCTAssertTrue(context.disableHeavyInit)
        XCTAssertEqual(context.testProfilePath, "/tmp/profile")
    }
}
