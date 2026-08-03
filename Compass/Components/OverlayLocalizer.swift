import Foundation

enum OverlayLocalizer {
    static func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
