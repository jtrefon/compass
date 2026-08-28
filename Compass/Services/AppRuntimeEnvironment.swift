import Foundation

enum AppRuntimeEnvironment {
    static let launchContext = AppLaunchContext.detect()

    nonisolated(unsafe) static let userDefaults: UserDefaults = {
        makeUserDefaults(for: launchContext)
    }()

    static func makeUserDefaults(for context: AppLaunchContext) -> UserDefaults {
        guard let testProfilePath = context.testProfilePath, !testProfilePath.isEmpty else {
            return .standard
        }

        let sanitized = testProfilePath
            .replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        let suiteName = "tdc.compass.test.\(sanitized)"
        return UserDefaults(suiteName: suiteName) ?? .standard
    }
}
