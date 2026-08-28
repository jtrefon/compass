import SwiftUI

struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let control: Control

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppConstants.Settings.rowSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: AppConstants.Settings.iconSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: AppConstants.Settings.iconFrameWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            control
        }
        .padding(.vertical, 4)
    }
}
