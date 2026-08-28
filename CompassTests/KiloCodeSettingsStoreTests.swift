import XCTest
@testable import Compass

final class KiloCodeSettingsStoreTests: XCTestCase {
    func testLoadMigratesLegacyGatewayBaseURL() {
        let suiteName = "KiloCodeSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let backingStore = SettingsStore(userDefaults: defaults)
        backingStore.set("https://api.kilo.ai/api/gateway", forKey: "KiloCodeBaseURL")

        let store = KiloCodeSettingsStore(settingsStore: backingStore)
        let settings = store.load(includeApiKey: false)

        XCTAssertEqual(settings.baseURL, KiloCodeSettingsStore.currentBaseURL)
    }
}
