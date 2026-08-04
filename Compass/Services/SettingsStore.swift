import Foundation
import Combine

final class SettingsStore: @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let changesSubject = PassthroughSubject<String, Never>()

    var changes: AnyPublisher<String, Never> {
        changesSubject.eraseToAnyPublisher()
    }

    init(userDefaults: UserDefaults = AppRuntimeEnvironment.userDefaults) {
        self.userDefaults = userDefaults
    }

    func string(forKey key: String) -> String? {
        userDefaults.string(forKey: key)
    }

    func double(forKey key: String) -> Double {
        userDefaults.double(forKey: key)
    }

    func integer(forKey key: String) -> Int {
        userDefaults.integer(forKey: key)
    }

    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        userDefaults.object(forKey: key) as? Bool ?? defaultValue
    }

    func stringArray(forKey key: String) -> [String]? {
        userDefaults.stringArray(forKey: key)
    }

    func dictionary(forKey key: String) -> [String: Any]? {
        userDefaults.dictionary(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) {
        userDefaults.set(value, forKey: key)
        changesSubject.send(key)
    }

    func removeObject(forKey key: String) {
        userDefaults.removeObject(forKey: key)
        changesSubject.send(key)
    }
}
