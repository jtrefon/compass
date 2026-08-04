import SwiftUI
import AppKit
import Foundation

struct GoToSymbolOverlayView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var workspace: WorkspaceStateManager
    @ObservedObject private var fileEditor: FileEditorStateManager
    @Binding var isPresented: Bool

    @State private var query: String = ""
    @State private var results: [WorkspaceSymbolLocation] = []
    @State private var isSearching: Bool = false
    @State private var searchTask: Task<Void, Never>?

    @State private var searchService: WorkspaceSymbolSearchService?

    init(appState: AppState, isPresented: Binding<Bool>) {
        self.appState = appState
        self._workspace = ObservedObject(wrappedValue: appState.workspace)
        self._fileEditor = ObservedObject(wrappedValue: appState.fileEditor)
        self._isPresented = isPresented
    }

    private var overlayHeader: OverlayHeaderConfiguration {
        OverlayHeaderConfiguration(
            title: OverlayLocalizer.localized("go_to_symbol.title"),
            placeholder: OverlayLocalizer.localized("go_to_symbol.placeholder"),
            query: $query,
            textFieldMinWidth: AppConstants.Overlay.textFieldMinWidth,
            showsProgress: isSearching,
            onSubmit: {
                Task { await refreshResults() }
            },
            onClose: {
                close()
            }
        )
    }

    var body: some View {
        overlayScaffold(using: overlayHeader) {
            List {
                ForEach(results, id: \.id) { item in
                    Button(action: {
                        open(item: item, openToSide: NSEvent.modifierFlags.contains(.command))
                    }) {
                        HStack(spacing: AppConstants.Overlay.listItemSpacing) {
                            Text(item.kind.rawValue)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: AppConstants.Overlay.listItemKindWidth, alignment: .leading)

                            Text(item.name)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            Text("\(item.relativePath):\(item.line)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: AppConstants.Overlay.listMinWidth, minHeight: AppConstants.Overlay.listMinHeight)
        }
        .onAppear {
            if searchService == nil {
                searchService = WorkspaceSymbolSearchService(codebaseIndexProvider: { appState.codebaseIndex })
            }
            query = ""
            Task { await refreshResults() }
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
            action: { await refreshResults() }
        )
    }

    @MainActor
    private func refreshResults() async {
        guard let root = workspace.currentDirectory?.standardizedFileURL else {
            results = []
            return
        }

        guard let searchService else {
            results = []
            return
        }

        let currentFilePath = fileEditor.selectedFile
        let currentLanguage = fileEditor.editorLanguage
        let currentContent = fileEditor.editorContent

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        isSearching = true
        let newResults = await searchService.search(
            WorkspaceSymbolSearchService.SearchRequest(
                rawQuery: trimmed,
                projectRoot: root,
                currentFilePath: currentFilePath,
                currentContent: currentContent,
                currentLanguage: currentLanguage,
                limit: 200
            )
        )
        self.results = newResults
        self.isSearching = false
    }

    private func openFirst(openToSide: Bool) {
        guard let first = results.first else { return }
        open(item: first, openToSide: openToSide)
    }

    private func open(item: WorkspaceSymbolLocation, openToSide: Bool) {
        guard let root = workspace.currentDirectory?.standardizedFileURL else { return }

        do {
            let url = try appState.workspaceService
                .makePathValidator(projectRoot: root)
                .validateAndResolve(item.relativePath)
            if openToSide {
                fileEditor.openInOtherPane(from: url)
            } else {
                appState.loadFile(from: url)
            }
            fileEditor.selectLine(item.line)
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
}
