import XCTest

@MainActor
final class WindowSizeUITests: BaseUITestCase {
    func testWindowWithinDisplayBounds() {
        let robot = launchApp()
        robot.window().assertWithinMainDisplayBounds()
    }
}
