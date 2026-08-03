import SwiftUI
import AppKit

struct QuickOpenOverlayView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var workspace: WorkspaceStateManager
    @ObservedObject private var fileEditor: FileEditorStateManager
    @Binding var isPresented: Bool

    @State private var query: String = ""
    @State private var results: [String] = []
    @State private var isSearching: Bool = false
    @State private var searchTask: Task<Void, Never>?

    init(appState: AppState, isPresented: Binding<Bool>) {
        self.appState = appState
        self._workspace = ObservedObject(wrappedValue: appState.workspace)
        self._fileEditor = ObservedObject(wrappedValue: appState.fileEditor)
        self._isPresented = isPresented
    }

    private var overlayHeader: OverlayHeaderConfiguration {
        OverlayHeaderConfiguration(
            title: OverlayLocalizer.localized("quick_open.title"),
            placeholder: OverlayLocalizer.localized("quick_open.placeholder"),
            query: $query,
            textFieldMinWidth: AppConstants.Overlay.textFieldMinWidth,
            showsProgress: isSearching,
            onSubmit: {
                openFirst(openToSide: NSEvent.modifierFlags.contains(.command))
            },
            onClose: {
                close()
            }
        )
    }

    var body: some View {
        overlayScaffold(using: overlayHeader) {
            List {
                if !recentCandidates().isEmpty && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section(OverlayLocalizer.localized("quick_open.recent")) {
                        ForEach(recentCandidates(), id: \.self) { path in
                            Button(action: { open(path: path, openToSide: false) }) {
                                Text(path)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section(OverlayLocalizer.localized("quick_open.results")) {
                    ForEach(results, id: \.self) { path in
                        Button(action: { open(path: path, openToSide: NSEvent.modifierFlags.contains(.command)) }) {
                            Text(path)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minWidth: AppConstants.Overlay.listMinWidth, minHeight: AppConstants.Overlay.listMinHeight)
        }
        .onAppear {
            query = ""
            results = []
        }
        .onChange(of: query) { _, _ in
            debounceSearch()
        }
        .onExitCommand {
            close()
        }
    }

    private func debounceSearch() {
        OverlaySearchDebouncer.reschedule(
            searchTask: &searchTask,
            debounceNanoseconds: AppConstants.Time.quickSearchDebounceNanoseconds,
            action: {
                await refreshResults()
            }
        )
    }

    private func refreshResults() async {
        guard let root = workspace.currentDirectory?.standardizedFileURL else {
            results = []
            return
        }

        let (fileQuery, _) = Self.parseQuery(query)
        let trimmed = fileQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            results = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        let settingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)
        if let index = appState.codebaseIndex,
           settingsStore.bool(forKey: AppConstants.Storage.codebaseIndexEnabledKey, default: true),
           let matches = try? await index.findIndexedFiles(query: trimmed, limit: 50) {
            results = matches.map { $0.path }
            return
        }

        results = fallbackFindFiles(query: trimmed, root: root, limit: 50)
    }

    private func fallbackFindFiles(query: String, root: URL, limit: Int) -> [String] {
        QuickOpenFileFinder().findFiles(query: query, root: root, limit: limit)
    }

    private func recentCandidates() -> [String] {
        guard let root = workspace.currentDirectory?.standardizedFileURL else { return [] }
        var output: [String] = []
        output.reserveCapacity(10)

        for url in workspace.recentlyOpenedFiles {
            if output.count >= 10 { break }
            guard url.path.hasPrefix(root.path + "/") else { continue }
            output.append(String(url.path.dropFirst(root.path.count + 1)))
        }

        return output
    }

    private func openFirst(openToSide: Bool) {
        guard let first = results.first else { return }
        open(path: first, openToSide: openToSide)
    }

    private func open(path: String, openToSide: Bool) {
        guard let root = workspace.currentDirectory?.standardizedFileURL else { return }
        let (_, line) = Self.parseQuery(query)

        do {
            let url = try appState.workspaceService.makePathValidator(projectRoot: root).validateAndResolve(path)
            if openToSide {
                fileEditor.openInOtherPane(from: url)
            } else {
                appState.loadFile(from: url)
            }
            if let line {
                fileEditor.selectLine(line)
            }
            close()
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func close() {
        searchTask?.cancel()
        isPresented = false
        query = ""
        results = []
        isSearching = false
    }

    static func parseQuery(_ raw: String) -> (fileQuery: String, line: Int?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return (trimmed, nil) }

        if let last = parts.last {
            if let line = Int(last) {
                let file = parts.dropLast().joined(separator: ":")
                return (String(file), max(1, line))
            }
        }

        return (trimmed, nil)
    }
}
