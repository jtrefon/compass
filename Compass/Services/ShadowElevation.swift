import SwiftUI

struct ShadowElevation {
    let radius: CGFloat
    let y: CGFloat
    let opacity: Double

    static let low = ShadowElevation(radius: 4, y: 1, opacity: 0.12)
    static let medium = ShadowElevation(radius: 8, y: 2, opacity: 0.15)
    static let high = ShadowElevation(radius: 16, y: 4, opacity: 0.18)
    static let overlay = ShadowElevation(radius: 30, y: 8, opacity: 0.20)
}

extension View {
    func elevation(_ level: ShadowElevation) -> some View {
        self.shadow(color: .black.opacity(level.opacity), radius: level.radius, x: 0, y: level.y)
    }
}
