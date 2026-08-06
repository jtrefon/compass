import Foundation
import SwiftUI

@MainActor
final class LocalModelSettingsViewModel: ObservableObject {
    struct Status: Equatable {
        enum Kind {
            case idle
            case loading
            case success
            case warning
            case error
        }

        let kind: Kind
        let message: String
    }

    /// The single fixed chat model (local MLX inference).
    let chatModel: LocalModelDefinition

    /// The single fixed FIM (inline completion) model.
    let fimModel: LocalModelDefinition

    @Published var offlineModeEnabled: Bool {
        didSet {
            persistOfflineModeEnabled()
        }
    }

    @Published var kvCache4BitEnabled: Bool {
        didSet {
            persistKVCache4BitEnabled()
        }
    }

    @Published var contextLength: Double {
        didSet {
            persistContextLength()
        }
    }

    @Published private(set) var status = Status(kind: .idle, message: "Local models not configured.")
    @Published private(set) var isDownloading = false
    @Published private(set) var progressFraction: Double = 0
    @Published private(set) var currentFileName: String? = nil
    @Published private(set) var progressText: String? = nil

    private let downloader: LocalModelDownloader
    private let settingsStore: SettingsStore
    private let selectionStore: LocalModelSelectionStore

    init(
        downloader: LocalModelDownloader = LocalModelDownloader(),
        settingsStore: SettingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)
    ) {
        self.downloader = downloader
        self.settingsStore = settingsStore
        self.selectionStore = LocalModelSelectionStore(settingsStore: settingsStore)
        self.chatModel = LocalModelCatalog.chatModel
        self.fimModel = LocalModelCatalog.fimModel
        self.offlineModeEnabled = settingsStore.bool(forKey: LocalModelSettingsKeys.offlineModeEnabled, default: false)
        self.kvCache4BitEnabled = settingsStore.bool(forKey: LocalModelSettingsKeys.kvCache4BitEnabled, default: true)
        let ctx = settingsStore.integer(forKey: LocalModelSettingsKeys.contextLength)
        self.contextLength = ctx > 0 ? Double(ctx) : Double(chatModel.defaultContextLength)
        updateOfflineStatusMessage()
    }

    func isInstalled(_ model: LocalModelDefinition) -> Bool {
        LocalModelFileStore.isModelInstalled(model)
    }

    func downloadModel(_ model: LocalModelDefinition) async {
        guard !isDownloading else { return }

        isDownloading = true
        progressFraction = 0
        currentFileName = nil
        progressText = nil
        status = Status(kind: .loading, message: "Downloading \(model.displayName)...")

        do {
            try await downloader.download(model: model) { [weak self] progress in
                Task { @MainActor in
                    self?.progressFraction = progress.fractionCompleted
                    self?.currentFileName = progress.currentFileName
                    
                    if let total = progress.currentFileBytesTotal, total > 0 {
                        let downloadedMB = Double(progress.currentFileBytesDownloaded) / 1_048_576.0
                        let totalMB = Double(total) / 1_048_576.0
                        self?.progressText = String(format: "%.1f MB / %.1f MB", downloadedMB, totalMB)
                    } else if progress.currentFileBytesDownloaded > 0 {
                        let downloadedMB = Double(progress.currentFileBytesDownloaded) / 1_048_576.0
                        self?.progressText = String(format: "%.1f MB downloaded", downloadedMB)
                    } else {
                        self?.progressText = nil
                    }
                }
            }

            updateOfflineStatusMessage()
        } catch {
            status = Status(kind: .error, message: error.localizedDescription)
        }

        isDownloading = false
        currentFileName = nil
        progressText = nil
    }

    private func persistOfflineModeEnabled() {
        let offlineModeEnabled = self.offlineModeEnabled
        Task {
            await selectionStore.setOfflineModeEnabled(offlineModeEnabled)
        }
        updateOfflineStatusMessage()
    }

    private func persistKVCache4BitEnabled() {
        let kvCache4BitEnabled = self.kvCache4BitEnabled
        Task {
            await selectionStore.setKVCache4BitEnabled(kvCache4BitEnabled)
        }
    }

    private func persistContextLength() {
        let length = Int(self.contextLength)
        Task {
            await selectionStore.setContextLength(length)
        }
    }

    private func updateOfflineStatusMessage() {
        guard offlineModeEnabled else {
            status = Status(kind: .idle, message: "Offline Mode disabled. Chat requests use the selected remote provider.")
            return
        }

        guard isInstalled(chatModel) else {
            status = Status(kind: .warning, message: "Offline Mode enabled, but \(chatModel.displayName) is not downloaded yet.")
            return
        }

        status = Status(kind: .success, message: "Offline Mode enabled. Chat requests route to \(chatModel.displayName).")
    }
}
