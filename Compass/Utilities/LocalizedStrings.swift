import Foundation

extension String {
    /// Localized string lookup. Shared across all components — historically
    /// every view file declared its own private copy.
    var localized: String { NSLocalizedString(self, comment: "") }
}

func localized(_ key: String) -> String {
    key.localized
}
