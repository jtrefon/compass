import SwiftUI

struct GlobalSearchOverlayView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var workspace: WorkspaceStateManager
    @ObservedObject private var fileEditor: FileEditorStateManager
    @Binding var isPresented: Bool

    private struct SearchResultGroup: Identifiable {
        let file: String
        let matches: [WorkspaceSearchMatch]

        var id: String { file }
    }

    @State private var query: String = ""
    @State private var isSearching: Bool = false
    @State private var resultsByFile: [SearchResultGroup] = []
    @State private var searchTask: Task<Void, Never>?

    private let searchService: WorkspaceSearchService

    init(appState: AppState, isPresented: Binding<Bool>) {
        self.appState = appState
        self._workspace = ObservedObject(wrappedValue: appState.workspace)
        self._fileEditor = ObservedObject(wrappedValue: appState.fileEditor)
        self._isPresented = isPresented
        self.searchService = WorkspaceSearchService(codebaseIndexProvider: { appState.codebaseIndex })
    }

    var body: some View {
        overlayScaffold(using: overlayHeader) {
            List {
                ForEach(resultsByFile) { group in
                    Section(group.file) {
                        ForEach(group.matches) { match in
                            Button(action: {
                                open(match: match, openToSide: false)
                            }) {
                                HStack {
                                    Text("\(match.line)")
                                        .font(.body.monospaced())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 60, alignment: .trailing)

                                    Text(match.snippet)
                                        .lineLimit(2)

                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(minWidth: AppConstants.Overlay.listMinWidth, minHeight: AppConstants.Overlay.listMinHeight)
        }
        .onAppear {
            if query.isEmpty {
                query = ""
            }
        }
        .onChange(of: query) { _, _ in
            debounceSearch()
        }
        .onExitCommand {
            close()
        }
    }

    private var overlayHeader: OverlayHeaderConfiguration {
        OverlayHeaderConfiguration(
            title: localized("global_search.title"),
            placeholder: localized("global_search.placeholder"),
            query: $query,
            textFieldMinWidth: AppConstants.Overlay.searchFieldMinWidth,
            showsProgress: isSearching,
            onSubmit: {
                Task { await triggerSearch() }
            },
            onClose: {
                close()
            }
        )
    }

    private func debounceSearch() {
        OverlaySearchDebouncer.reschedule(
            searchTask: &searchTask,
            debounceNanoseconds: AppConstants.Time.quickSearchDebounceNanoseconds,
            action: { await triggerSearch() }
        )
    }

    @MainActor
    private func triggerSearch() async {
        guard let root = workspace.currentDirectory?.standardizedFileURL else {
            resultsByFile = []
            return
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            resultsByFile = []
            return
        }

        searchTask?.cancel()
        searchTask = Task { @MainActor in
            isSearching = true
            defer { isSearching = false }

            let matches = await searchService.search(pattern: needle, projectRoot: root, limit: 400)
            resultsByFile = Self.group(matches)
        }
    }

    private func open(match: WorkspaceSearchMatch, openToSide: Bool) {
        guard let root = workspace.currentDirectory?.standardizedFileURL else { return }

        do {
            let url = try appState.workspaceService
                .makePathValidator(projectRoot: root)
                .validateAndResolve(match.relativePath)
            if openToSide {
                fileEditor.openInOtherPane(from: url)
            } else {
                appState.loadFile(from: url)
            }
            fileEditor.selectLine(match.line)
            close()
        } catch {
            appState.lastError = error.localizedDescription
        }
    }

    private func close() {
        searchTask?.cancel()
        isPresented = false
        isSearching = false
        query = ""
        resultsByFile = []
    }

    private static func group(_ matches: [WorkspaceSearchMatch]) -> [SearchResultGroup] {
        let grouped = Dictionary(grouping: matches, by: { $0.relativePath })
        let sortedKeys = grouped.keys.sorted()
        return sortedKeys.map { key in
            let sorted = (grouped[key] ?? []).sorted { $0.line < $1.line }
            return SearchResultGroup(file: key, matches: sorted)
        }
    }
}
