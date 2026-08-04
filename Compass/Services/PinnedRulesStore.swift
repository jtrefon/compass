import Foundation

public enum PinnedRulesStore {
    public static let maxCount = 10

    public static func load(projectRoot: URL) -> [String] {
        let url = projectRoot.appendingPathComponent(AppConstantsFileSystem.projectDirName).appendingPathComponent("pinned-rules.json")
        guard let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return rules
    }

    public static func save(_ rules: [String], projectRoot: URL) throws {
        var rules = rules
        if rules.count > maxCount {
            rules = Array(rules.prefix(maxCount))
        }
        let url = projectRoot.appendingPathComponent(AppConstantsFileSystem.projectDirName).appendingPathComponent("pinned-rules.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(rules)
        try data.write(to: url, options: .atomic)
    }
}
