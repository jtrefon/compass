import SwiftUI

enum NativeGlassSurface {
    case header
    case sidebar
    case panel
    case toolbar
    case popover
    case sheet

    /// macOS 26 liquid-glass level. The previous implementation was hand-rolled
    /// ShapeStyle materials (classic vibrancy) — the app rendered two different
    /// "glass" families side by side (liquid pills next to material panels).
    /// This SDK exposes `Glass.regular` only; keep one level for consistency.
    var glass: Glass { .regular }

    var defaultCornerRadius: CGFloat {
        switch self {
        case .header:  return AppConstants.Layout.cornerSm
        case .sidebar: return 0
        case .panel:   return AppConstants.Layout.cornerLg
        case .toolbar: return AppConstants.Layout.cornerSm
        case .popover: return AppConstants.Layout.cornerMd
        case .sheet:   return AppConstants.Layout.cornerLg
        }
    }
}

extension View {
    /// macOS 26 liquid-glass surface (`.glassEffect(_:in:)`), clipped to the
    /// surface's corner shape. All glass call sites share this one entry point.
    @ViewBuilder
    func nativeGlassBackground(_ surface: NativeGlassSurface, cornerRadius: CGFloat? = nil, showBorder: Bool = false) -> some View {
        let radius = cornerRadius ?? surface.defaultCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        self
            .glassEffect(surface.glass, in: shape)
            .overlay(
                showBorder
                    ? shape.stroke(AppConstants.Color.separatorSubtle, lineWidth: 0.5)
                    : nil
            )
    }
}
