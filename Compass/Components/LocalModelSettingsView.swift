import SwiftUI

struct LocalModelSettingsView: View {
    @ObservedObject var viewModel: LocalModelSettingsViewModel

    private var kvCacheCaption: String {
        let ctx = Int(viewModel.contextLength)
        let q4MB = LocalModelSettingsViewModel.estimatedKVCacheMB(contextLength: ctx, kvBits: 4)
        let fp16MB = LocalModelSettingsViewModel.estimatedKVCacheMB(contextLength: ctx, kvBits: 16)
        return viewModel.kvCache4BitEnabled
            ? "4-bit KV: ~\(q4MB) MB resident at \(ctx) tokens. Uses non-fused quantized attention (slower decode, larger transient peak). Best for 32+ GB machines with long contexts."
            : "FP16 KV: ~\(fp16MB) MB resident at \(ctx) tokens. Uses fused flash attention (faster decode, lower transient peak). Recommended for 16 GB machines."
    }

    var body: some View {
        Form {
            Section {
                Toggle("Offline Mode (disable OpenRouter)", isOn: $viewModel.offlineModeEnabled)
            } header: {
                Text("Local Models")
            }

            Section {
                Slider(value: $viewModel.contextLength, in: 2048...262_144, step: 1024) {
                    Text("Context Length: \(Int(viewModel.contextLength)) tokens")
                }

                Toggle("Quantize KV cache (4-bit)", isOn: $viewModel.kvCache4BitEnabled)

                Text(kvCacheCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LocalModelRoleRow(
                    title: "Chat model",
                    model: viewModel.chatModel,
                    isInstalled: viewModel.isInstalled(viewModel.chatModel),
                    isDownloading: viewModel.isDownloading,
                    onDownload: {
                        Task { await viewModel.downloadModel(viewModel.chatModel) }
                    }
                )

                LocalModelRoleRow(
                    title: "Completion model",
                    model: viewModel.fimModel,
                    isInstalled: viewModel.isInstalled(viewModel.fimModel),
                    isDownloading: viewModel.isDownloading,
                    onDownload: {
                        Task { await viewModel.downloadModel(viewModel.fimModel) }
                    }
                )

                LocalModelStatusLine(
                    status: viewModel.status,
                    progressFraction: viewModel.progressFraction,
                    currentFileName: viewModel.currentFileName,
                    progressText: viewModel.progressText,
                    isDownloading: viewModel.isDownloading
                )
            }
        }
        .formStyle(.grouped)
    }
}

/// One fixed role row — no model choice, only install state + download.
private struct LocalModelRoleRow: View {
    let title: String
    let model: LocalModelDefinition
    let isInstalled: Bool
    let isDownloading: Bool
    let onDownload: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))

                Text(isInstalled ? "Installed" : "Not downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(isInstalled ? "Re-download" : "Download") {
                onDownload()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDownloading)
        }
    }
}

private struct LocalModelStatusLine: View {
    let status: LocalModelSettingsViewModel.Status
    let progressFraction: Double
    let currentFileName: String?
    let progressText: String?
    let isDownloading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isDownloading {
                ProgressView(value: progressFraction)
                    .frame(width: 420)

                if let currentFileName {
                    HStack {
                        Text(currentFileName)
                        Spacer()
                        if let progressText {
                            Text(progressText)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 420)
                }
            }

            Text(status.message)
                .font(.caption)
                .foregroundStyle(color(for: status.kind))
        }
    }

    private func color(for kind: LocalModelSettingsViewModel.Status.Kind) -> Color {
        switch kind {
        case .idle:
            return .secondary
        case .loading:
            return .secondary
        case .success:
            return .green
        case .warning:
            return .yellow
        case .error:
            return .red
        }
    }
}
