import XCTest

@MainActor
class BaseUITestCase: XCTestCase {
    private(set) var app: XCUIApplication!
    private var testProfilePath: String = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        testProfilePath = NSTemporaryDirectory() + "Compass_ui_profile_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: testProfilePath, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if app.state == .runningForeground || app.state == .runningBackground {
            app.terminate()
        }
        if !testProfilePath.isEmpty {
            try? FileManager.default.removeItem(atPath: testProfilePath)
        }
    }

    @discardableResult
    func launchApp(scenario: String? = nil) -> AppRobot {
        app.launchEnvironment[TestLaunchKeys.xcuiTesting] = "1"
        app.launchEnvironment[TestLaunchKeys.testProfileDir] = testProfilePath
        app.launchEnvironment[TestLaunchKeys.disableHeavyInit] = "1"
        app.launchEnvironment["COMPASS_DISABLE_INLINE_COMPLETION"] = "1"
        if let scenario {
            app.launchEnvironment[TestLaunchKeys.uiTestScenario] = scenario
        }

        app.launch()
        let robot = AppRobot(app: app)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "App must reach foreground")
        app.activate()
        XCTAssertTrue(robot.window().mainWindow.exists, "Main window must exist on launch")
        return robot
    }
}

enum TestLaunchKeys {
    static let xcuiTesting = "XCUI_TESTING"
    static let testProfileDir = "COMPASS_TEST_PROFILE_DIR"
    static let disableHeavyInit = "COMPASS_DISABLE_HEAVY_INIT"
    static let uiTestScenario = "COMPASS_TEST_SCENARIO"
}

enum UITestAccessibilityID {
    static let appRootView = "AppRootView"
    static let appReadyMarker = "AppReadyMarker"
    static let codeEditorTextView = "CodeEditorTextView"
    static let aiChatPanel = "AIChatPanel"
    static let aiChatInputTextView = "AIChatInputTextView"
    static let aiChatSendButton = "AIChatSendButton"
    static let aiChatNewConversationButton = "AIChatNewConversationButton"
    static let terminalTextView = "TerminalTextView"
    static let fileExplorerOutline = "FileExplorerOutline"
    static let statusBar = "StatusBar"
    static let leftSidebarPanel = "LeftSidebarPanel"
    static let rightChatPanel = "RightChatPanel"
}

@MainActor
struct AppRobot {
    let app: XCUIApplication

    func window() -> WindowRobot { WindowRobot(app: app) }
}

@MainActor
struct WindowRobot {
    let app: XCUIApplication

    var mainWindow: XCUIElement { app.windows.firstMatch }

    func assertWithinMainDisplayBounds() {
        let frame = mainWindow.frame
        let displayBounds = CGDisplayBounds(CGMainDisplayID())
        XCTAssertGreaterThan(frame.width, 0, "Window width must be positive")
        XCTAssertGreaterThan(frame.height, 0, "Window height must be positive")
        XCTAssertLessThanOrEqual(frame.width, displayBounds.width, "Window must fit within display width")
        XCTAssertLessThanOrEqual(frame.height, displayBounds.height, "Window must fit within display height")
        XCTAssertGreaterThanOrEqual(frame.minX, displayBounds.minX, "Window must not extend left of display")
        XCTAssertGreaterThanOrEqual(frame.minY, displayBounds.minY, "Window must not extend above display")
    }
}

@MainActor
final class CompassUITests: BaseUITestCase {
    func testAppLaunchesAndBecomesReady() {
        let robot = launchApp()
        XCTAssertTrue(robot.window().mainWindow.exists, "Main window must exist after launch")
    }
}
