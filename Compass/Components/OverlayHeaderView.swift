import SwiftUI

struct OverlayHeaderView: View {
    let title: String
    let placeholder: String
    @Binding var query: String
    let textFieldMinWidth: CGFloat
    let showsProgress: Bool
    let onSubmit: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: AppConstants.Layout.spacingSm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppConstants.Layout.compactIconSize))
                .foregroundStyle(AppConstants.Color.textSecondary)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppConstants.Color.textSecondary)

            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.body)
                .frame(minWidth: textFieldMinWidth)
                .onSubmit {
                    onSubmit()
                }

            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            }

            IDEIconButton(
                symbol: "xmark",
                accessibilityLabel: NSLocalizedString("common.close", comment: ""),
                action: onClose
            )
        }
        .padding(.horizontal, AppConstants.Layout.spacingSm)
        .frame(height: AppConstants.Layout.headerHeight)
    }
}
