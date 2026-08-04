import SwiftUI

struct FileExplorerView<Context: IDEContext & ObservableObject>: View {
    @ObservedObject var context: Context
    @State private var searchQuery: String = ""
    @State private var refreshToken: Int = 0
    @State private var isSearchVisible = false
    @FocusState private var isSearchFocused: Bool

    private var showHiddenFiles: Bool { context.showHiddenFilesInFileTree }

    @State private var isShowingNewFileSheet = false
    @State private var isShowingNewFolderSheet = false
    @State private var newFileName: String = ""
    @State private var newFolderName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar — hidden by default, shown on Cmd+F
            if isSearchVisible {
                HStack(spacing: AppConstants.Layout.spacingXS) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(localized("file_explorer.search.placeholder"), text: $searchQuery)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AppConstants.Layout.spacingSm)
                .padding(.vertical, AppConstants.Layout.rowVerticalPadding)
                .nativeGlassBackground(.header)
            }

            // File tree
            ModernFileTreeView(
                rootURL: context.workspace.currentDirectory
                    ?? FileManager.default.temporaryDirectory,
                searchQuery: $searchQuery,
                expandedRelativePaths: Binding(
                    get: { context.fileTreeExpandedRelativePaths },
                    set: { context.fileTreeExpandedRelativePaths = $0 }
                ),
                selectedRelativePath: Binding(
                    get: { context.fileTreeSelectedRelativePath },
                    set: { context.fileTreeSelectedRelativePath = $0 }
                ),
                showHiddenFiles: showHiddenFiles,
                refreshToken: refreshToken,
                onOpenFile: { url in
                    Task {
                        try? await context.commandRegistry.execute(
                            .explorerOpenSelection,
                            args: ExplorerPathArgs(path: url.path)
                        )
                    }
                },
                onCreateFile: { directory, name in
                    Task {
                        await context.workspaceService.createFile(named: name, in: directory)
                        refreshToken += 1
                    }
                },
                onCreateFolder: { directory, name in
                    Task {
                        await context.workspaceService.createFolder(named: name, in: directory)
                        refreshToken += 1
                    }
                },
                onDeleteItem: { url in
                    Task {
                        try? await context.commandRegistry.execute(
                            .explorerDeleteSelection,
                            args: ExplorerPathArgs(path: url.path)
                        )
                        await MainActor.run {
                            refreshToken += 1
                            syncSelectionFromAppState()
                        }
                    }
                },
                onRenameItem: { url, newName in
                    Task {
                        try? await context.commandRegistry.execute(
                            .explorerRenameSelection,
                            args: ExplorerRenameArgs(path: url.path, newName: newName)
                        )
                        await MainActor.run {
                            refreshToken += 1
                            syncSelectionFromAppState()
                        }
                    }
                },
                onRevealInFinder: { url in
                    Task {
                        try? await context.commandRegistry.execute(
                            .explorerRevealInFinder,
                            args: ExplorerPathArgs(path: url.path)
                        )
                    }
                },
                fontSize: context.ui.fontSize,
                fontFamily: context.ui.fontFamily
            )
            .background(AppConstants.Color.surfaceSidebar)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .sheet(isPresented: $isShowingNewFileSheet) {
                VStack(spacing: 20) {
                    Text(localized("file_tree.create_file.title"))
                        .font(.headline)
                    TextField(localized("file_tree.create_file.name_placeholder"), text: $newFileName)
                        .textFieldStyle(.roundedBorder)
                        .padding()
                        .onSubmit { createNewFile() }
                    HStack {
                        Button(localized("common.cancel")) { isShowingNewFileSheet = false }
                        Spacer()
                        Button(localized("common.create")) { createNewFile() }
                            .disabled(newFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal)
                }
                .padding()
                .frame(width: 300)
            }
            .sheet(isPresented: $isShowingNewFolderSheet) {
                VStack(spacing: 20) {
                    Text(localized("file_tree.create_folder.title")).font(.headline)
                    TextField(localized("file_tree.create_folder.name_placeholder"), text: $newFolderName)
                        .textFieldStyle(.roundedBorder)
                        .padding()
                        .onSubmit { createNewFolder() }
                    HStack {
                        Button(localized("common.cancel")) { isShowingNewFolderSheet = false }
                        Spacer()
                        Button(localized("common.create")) { createNewFolder() }
                            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal)
                }
                .padding()
                .frame(width: 300)
            }
        }
        .frame(minWidth: 200)
        .background(AppConstants.Color.surfaceSidebar)
        .onAppear { syncSelectionFromAppState() }
        .onReceive(context.workspace.$currentDirectory) { _ in
            refreshToken += 1
            syncSelectionFromAppState()
        }
        .onChange(of: context.fileTreeRefreshToken) { _, _ in
            refreshToken = context.fileTreeRefreshToken
        }
        .onChange(of: context.fileEditor.selectedFile) { _, _ in
            syncSelectionFromAppState()
        }
        .onChange(of: isSearchVisible) { _, visible in
            if visible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isSearchFocused = true
                }
            } else {
                searchQuery = ""
            }
        }
        // Cmd+F: toggle search bar | Esc: hide search bar
        .background(
            Button("") { isSearchVisible.toggle() }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
        )
        .background(
            Button("") { isSearchVisible = false }
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
        )
    }

    private func syncSelectionFromAppState() {
        guard let selectedFilePath = context.fileEditor.selectedFile else {
            context.fileTreeSelectedRelativePath = nil
            return
        }
        context.fileTreeSelectedRelativePath = context.relativePath(for: URL(fileURLWithPath: selectedFilePath))
    }

    private func createNewFile() {
        let trimmedName = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { isShowingNewFileSheet = false; return }
        isShowingNewFileSheet = false
        Task {
            await context.workspace.createFile(named: trimmedName)
            refreshToken += 1
        }
    }

    private func createNewFolder() {
        let trimmedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { isShowingNewFolderSheet = false; return }
        isShowingNewFolderSheet = false
        Task {
            await context.workspace.createFolder(named: trimmedName)
            refreshToken += 1
        }
    }
}
