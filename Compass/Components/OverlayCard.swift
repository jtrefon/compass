import SwiftUI

struct OverlayCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(AppConstants.Overlay.containerPadding)
            .nativeGlassBackground(.panel, cornerRadius: AppConstants.Overlay.containerCornerRadius, showBorder: true)
            .elevation(.overlay)
    }
}
