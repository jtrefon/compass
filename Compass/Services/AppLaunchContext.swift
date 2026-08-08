import Foundation

enum AppLaunchMode: Equatable {
    case app
    case unitTest
    case uiTest
}

struct AppLaunchContext: Equatable {
    let mode: AppLaunchMode
    let isTesting: Bool
    let isUITesting: Bool
    let testProfilePath: String?
    let disableHeavyInit: Bool
    let productionParityHarness: Bool

    init(
        mode: AppLaunchMode,
        isTesting: Bool,
        isUITesting: Bool,
        testProfilePath: String?,
        disableHeavyInit: Bool,
        productionParityHarness: Bool
    ) {
        self.mode = mode
        self.isTesting = isTesting
        self.isUITesting = isUITesting
        self.testProfilePath = testProfilePath
        self.disableHeavyInit = disableHeavyInit
        self.productionParityHarness = productionParityHarness
    }

    /// Test-constructed context (pressure-policy unit tests).
    init(
        isTesting: Bool,
        testProfilePath: String? = nil,
        disableHeavyInit: Bool = false,
        productionParityHarness: Bool = false
    ) {
        self.mode = isTesting ? .unitTest : .app
        self.isTesting = isTesting
        self.isUITesting = false
        self.testProfilePath = testProfilePath
        self.disableHeavyInit = disableHeavyInit
        self.productionParityHarness = productionParityHarness
    }

    static func detect(
        processInfo: ProcessInfo = .processInfo,
        environmentOverride: [String: String]? = nil
    ) -> AppLaunchContext {
        let env = environmentOverride ?? processInfo.environment
        // xcodebuild does NOT propagate env vars into the app-hosted test
        // process, so run.sh ALSO writes the test profile dir into the app's
        // standard defaults under COMPASS.TestProfileDir. Honor it only for
        // test-launched processes (never for normal app launches).
        let hasXCTestConfig = env["XCTestConfigurationFilePath"] != nil
        let isUITesting = env[TestLaunchKeys.xcuiTesting] == "1"
        let mode: AppLaunchMode

        if isUITesting {
            mode = .uiTest
        } else if hasXCTestConfig {
            mode = .unitTest
        } else {
            mode = .app
        }

        func value(_ key: String) -> String? {
            if let v = env[key] ?? env["TEST_RUNNER_ENV_\(key)"], !v.isEmpty { return v }
            if hasXCTestConfig || isUITesting {
                if let v = UserDefaults.standard.string(forKey: "COMPASS.TestProfile\(key)"), !v.isEmpty {
                    return v
                }
                if key == TestLaunchKeys.testProfileDir {
                    // run.sh writes a marker file into the sandboxed app
                    // container (defaults writes get clobbered by cfprefsd).
                    let marker = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Application Support/compass-test-profile-path")
                    if let v = try? String(contentsOf: marker, encoding: .utf8), !v.isEmpty {
                        return v
                    }
                }
            }
            return nil
        }

        let disableHeavyInit = value(TestLaunchKeys.disableHeavyInit) == "1" || isUITesting
        let productionParityHarness = value(TestLaunchKeys.productionParityHarness) == "1"
        let testProfilePath = value(TestLaunchKeys.testProfileDir)

        return AppLaunchContext(
            mode: mode,
            isTesting: hasXCTestConfig || isUITesting,
            isUITesting: isUITesting,
            testProfilePath: testProfilePath,
            disableHeavyInit: disableHeavyInit,
            productionParityHarness: productionParityHarness
        )
    }
}
