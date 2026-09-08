import SwiftUI

struct ShadowElevation {
    let radius: CGFloat
    let y: CGFloat
    let opacity: Double

    static let overlay = ShadowElevation(radius: 30, y: 8, opacity: 0.20)
}

extension View {
    func elevation(_ level: ShadowElevation) -> some View {
        self.shadow(color: .black.opacity(level.opacity), radius: level.radius, x: 0, y: level.y)
    }
}
