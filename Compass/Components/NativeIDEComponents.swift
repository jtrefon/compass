import SwiftUI

/// Shared, low-chrome controls for the workspace. These intentionally avoid
/// persistent labels and toolbar bands; labels remain available to VoiceOver
/// and in hover help while the workspace stays focused on content.
struct IDEIconButton: View {
    let symbol: String
    let accessibilityLabel: String
    var help: String? = nil
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: AppConstants.Layout.compactIconSize, weight: .medium))
                .foregroundStyle(isEnabled ? AppConstants.Color.textSecondary : AppConstants.Color.textTertiary)
                .frame(
                    width: AppConstants.Layout.iconButtonHitSize,
                    height: AppConstants.Layout.iconButtonHitSize
                )
                .background {
                    RoundedRectangle(cornerRadius: AppConstants.Layout.cornerSm, style: .continuous)
                        .fill(isHovered ? AppConstants.Color.controlHover : Color.clear)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityLabel)
        .help(help ?? accessibilityLabel)
    }
}

/// A restrained panel heading for places where orientation is necessary.
/// It deliberately contains no permanently visible action strip.
struct WorkspacePanelHeader<Trailing: View>: View {
    let title: String
    private let trailing: Trailing

    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: AppConstants.Layout.spacingSm) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppConstants.Color.textSecondary)
                .textCase(.uppercase)
                .lineLimit(1)

            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, AppConstants.Layout.spacingSm)
        .frame(height: AppConstants.Layout.headerHeight)
        .nativeGlassBackground(.header, cornerRadius: 0)
        .overlay(alignment: .bottom) {
            IDESectionDivider()
        }
    }
}

extension WorkspacePanelHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

struct IDESectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppConstants.Color.separatorDefault)
            .frame(height: AppConstants.Layout.panelDividerVisibleThickness)
    }
}

/// The shared pill label for toolbar dropdown selectors (AI mode, model picker).
/// Both selectors must render with the same idiom — mismatched native Picker vs
/// hand-rolled Button bubbles were a past regression.
struct IDECapsuleDropdownLabel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: AppConstants.Layout.spacingXS) {
            content()
            Image(systemName: "chevron.down")
                .font(.system(size: AppConstants.Layout.controlChevronSize))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AppConstants.Layout.controlHPadding)
        .frame(height: AppConstants.Layout.controlHeight)
    }
}

struct IDEStatusItem: View {
    let title: String
    var systemImage: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action, label: content)
                    .buttonStyle(.plain)
            } else {
                content()
            }
        }
        .foregroundStyle(AppConstants.Color.textSecondary)
        .font(.caption)
        .lineLimit(1)
    }

    @ViewBuilder
    private func content() -> some View {
        HStack(spacing: AppConstants.Layout.spacingXXS) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
    }
}
