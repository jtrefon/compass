import SwiftUI

enum AppConstantsColor {
    static let surfaceBackground = Color(nsColor: .windowBackgroundColor)
    static let surfaceSidebar = Color(nsColor: .controlBackgroundColor)
    static let surfaceCard = Color(nsColor: .controlBackgroundColor)
    static let surfaceElevated = Color(nsColor: .windowBackgroundColor)
    static let surfaceEditor = Color(nsColor: .textBackgroundColor)
    static let surfaceComposer = Color(nsColor: .controlBackgroundColor)

    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    static let accentDefault = Color.accentColor
    static let accentSubtle = Color.accentColor.opacity(0.12)
    static let focusRing = Color.accentColor.opacity(0.45)
    static let controlHover = Color(nsColor: .windowBackgroundColor).opacity(0.5)
    static let controlIdle = Color(nsColor: .windowBackgroundColor).opacity(0.35)
    static let textOnAccent = Color.white

    // Semantic status palette (replaces hand-rolled Color.green/orange/red fills)
    static let statusIdle = Color(nsColor: .secondaryLabelColor)
    static let statusActive = Color.blue.opacity(0.8)
    static let statusSuccess = Color.green.opacity(0.8)
    static let statusWarning = Color.orange.opacity(0.9)
    static let statusError = Color.red.opacity(0.9)
    static let statusSuccessSubtle = Color.green.opacity(0.12)
    static let statusWarningSubtle = Color.orange.opacity(0.12)
    static let statusErrorSubtle = Color.red.opacity(0.12)

    static let terminalForeground = Color(nsColor: .textColor)
    static let terminalBackground = Color(nsColor: .textBackgroundColor)

    static let separatorSubtle = Color(nsColor: .separatorColor).opacity(0.25)
    static let separatorDefault = Color(nsColor: .separatorColor)
    static let dividerHover = Color(nsColor: .separatorColor)

    // MARK: - Alerts
    static let alertError = Color(nsColor: .systemRed)
    static let alertWarning = Color(nsColor: .systemOrange)
    static let alertInfo = Color(nsColor: .systemBlue)
}
