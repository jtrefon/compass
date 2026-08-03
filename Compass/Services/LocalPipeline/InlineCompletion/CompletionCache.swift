import Foundation

@MainActor
final class CompletionCache {
    struct Entry {
        let value: [String]
        let createdAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 20) {
        self.ttl = ttl
    }

    func value(forKey key: String) -> [String]? {
        guard let entry = entries[key] else { return nil }
        if Date().timeIntervalSince(entry.createdAt) > ttl {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    func insert(_ value: [String], forKey key: String) {
        entries[key] = Entry(value: value, createdAt: Date())
    }
}

