import SwiftUI

struct SettingsStatusPill: View {
    let status: OpenRouterSettingsViewModel.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(status.message)
                .font(.system(size: AppConstants.Settings.statusTextSize))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .overlay(
            Capsule()
                .stroke(AppConstants.Color.separatorSubtle, lineWidth: 0.6)
        )
    }

    private var statusColor: Color {
        switch status.kind {
        case .idle: return AppConstants.Color.statusIdle
        case .loading: return AppConstants.Color.statusActive
        case .success: return AppConstants.Color.statusSuccess
        case .warning: return AppConstants.Color.statusWarning
        case .error: return AppConstants.Color.statusError
        }
    }
}
