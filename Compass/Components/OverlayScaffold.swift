import SwiftUI

struct OverlayScaffold<Content: View>: View {
    let configuration: OverlayScaffoldConfiguration
    @Binding var query: String
    private let content: Content

    init(
        configuration: OverlayScaffoldConfiguration,
        query: Binding<String>,
        @ViewBuilder content: () -> Content
    ) {
        self.configuration = configuration
        self._query = query
        self.content = content()
    }

    var body: some View {
        OverlayCard {
            VStack(spacing: 12) {
                OverlayHeaderView(
                    title: configuration.title,
                    placeholder: configuration.placeholder,
                    query: $query,
                    textFieldMinWidth: configuration.textFieldMinWidth,
                    showsProgress: configuration.showsProgress,
                    onSubmit: configuration.onSubmit,
                    onClose: configuration.onClose
                )

                content
            }
        }
    }
}
