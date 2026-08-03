import SwiftUI

struct OverlayHeaderConfiguration {
    let title: String
    let placeholder: String
    let query: Binding<String>
    let textFieldMinWidth: CGFloat
    let showsProgress: Bool
    let onSubmit: () -> Void
    let onClose: () -> Void
}

extension View {
    @ViewBuilder
    func overlayScaffold(
        using config: OverlayHeaderConfiguration,
        @ViewBuilder content: () -> some View
    ) -> some View {
        OverlayScaffold(
            configuration: OverlayScaffoldConfiguration(
                title: config.title,
                placeholder: config.placeholder,
                textFieldMinWidth: config.textFieldMinWidth,
                showsProgress: config.showsProgress,
                onSubmit: config.onSubmit,
                onClose: config.onClose
            ),
            query: config.query,
            content: content
        )
    }
}
