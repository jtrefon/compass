import Foundation
import AppKit

enum UILayoutNormalizer {
    private static let baselineMinWindowWidth: CGFloat = 700
    private static let baselineMinWindowHeight: CGFloat = 480
    private static let fallbackDefaultWindowWidth: CGFloat = 1280
    private static let fallbackDefaultWindowHeight: CGFloat = 800

    static func normalizedMinWindowSize(screenVisibleFrame: NSRect) -> NSSize {
        let width = min(baselineMinWindowWidth, screenVisibleFrame.width)
        let height = min(baselineMinWindowHeight, screenVisibleFrame.height)
        return NSSize(width: max(500, width), height: max(360, height))
    }

    static func normalizedDefaultWindowFrame(screenVisibleFrame: NSRect) -> NSRect {
        let width = min(fallbackDefaultWindowWidth, screenVisibleFrame.width)
        let height = min(fallbackDefaultWindowHeight, screenVisibleFrame.height)
        let origin = NSPoint(
            x: screenVisibleFrame.midX - (width / 2),
            y: screenVisibleFrame.midY - (height / 2)
        )
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    static func normalizeWindowFrame(_ frame: NSRect, screenVisibleFrame: NSRect) -> NSRect {
        var normalized = frame
        let minSize = normalizedMinWindowSize(screenVisibleFrame: screenVisibleFrame)

        normalized.size.width = min(max(normalized.size.width, minSize.width), screenVisibleFrame.width)
        normalized.size.height = min(max(normalized.size.height, minSize.height), screenVisibleFrame.height)

        if normalized.origin.x < screenVisibleFrame.minX {
            normalized.origin.x = screenVisibleFrame.minX
        }
        if normalized.maxX > screenVisibleFrame.maxX {
            normalized.origin.x = screenVisibleFrame.maxX - normalized.width
        }
        if normalized.origin.y < screenVisibleFrame.minY {
            normalized.origin.y = screenVisibleFrame.minY
        }
        if normalized.maxY > screenVisibleFrame.maxY {
            normalized.origin.y = screenVisibleFrame.maxY - normalized.height
        }

        return normalized
    }

    static func normalizeSidebarWidth(_ width: Double, windowWidth: CGFloat) -> Double {
        max(AppConstants.Layout.minSidebarWidth, width)
    }

    static func normalizeChatPanelWidth(_ width: Double, windowWidth: CGFloat) -> Double {
        max(AppConstants.Layout.minChatPanelWidth, width)
    }

    static func normalizeTerminalHeight(_ height: Double, windowHeight: CGFloat) -> Double {
        max(AppConstants.Layout.minTerminalHeight, height)
    }
}
