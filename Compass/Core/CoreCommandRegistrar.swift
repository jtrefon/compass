import AppKit

@MainActor
struct CoreCommandRegistrar<Context: IDEContext & ObservableObject> {
    let commandRegistry: CommandRegistry
    let context: Context

    func registerAll() {
        registerFileCommands()
        registerEditorCommands()
        registerViewCommands()
        registerWorkbenchCommands()
        registerExplorerCommands()
    }

    private func registerFileCommands() {
        commandRegistry.register(command: .fileNew) { _ in
            context.fileEditor.newFile()
        }

        commandRegistry.register(command: .projectNew) { _ in
            context.newProject()
        }

        commandRegistry.register(command: .fileOpen) { _ in
            context.openFile()
        }

        commandRegistry.register(command: .fileOpenFolder) { _ in
            Task { await context.workspace.openFolder() }
        }

        commandRegistry.register(command: .fileSave) { _ in
            context.fileEditor.saveFile()
        }

        commandRegistry.register(command: .fileSaveAs) { _ in
            Task { await context.fileEditor.saveFileAs() }
        }
    }

    private func registerEditorCommands() {
        commandRegistry.register(command: .editorFormat) { _ in
            let content = context.fileEditor.editorContent
            let languageStr = context.fileEditor.editorLanguage
            let language = CodeLanguage(rawValue: languageStr) ?? .unknown
            context.fileEditor.editorContent = CodeFormatter.format(content, language: language)
        }

        registerNavigationCommands()
        registerEditorStateCommands()
        registerTextFinderCommands()
        registerMultiCursorCommands()
        registerInlineCompletionCommand()
        registerInlineAIAssistCommand()
    }

    private func registerNavigationCommands() {
        registerGoToDefinitionCommand()
        registerFindReferencesCommand()
        registerRenameSymbolCommand()
    }

    private func registerGoToDefinitionCommand() {
        commandRegistry.register(command: .editorGoToDefinition) { _ in
            guard let root = context.workspace.currentDirectory?.standardizedFileURL else { return }

            guard let identifier = resolveWorkspaceIdentifier() else {
                context.lastError = "No symbol selected"
                return
            }

            let content = context.fileEditor.editorContent

            Task { @MainActor in
                let svc = WorkspaceNavigationService(codebaseIndexProvider: { context.codebaseIndex })
                let locations = await svc.findDefinitionLocations(
                    WorkspaceNavigationService.FindDefinitionRequest(
                        identifier: identifier,
                        projectRoot: root,
                        currentFilePath: context.fileEditor.selectedFile,
                        currentContent: content,
                        currentLanguage: context.fileEditor.editorLanguage,
                        limit: 50
                    )
                )

                if locations.isEmpty {
                    context.lastError = "No definition found for \"\(identifier)\"."
                    return
                }

                if locations.count == 1, let only = locations.first {
                    openWorkspaceLocation(only, projectRoot: root)
                    return
                }

                context.navigationLocationsTitle = "Definitions for \"\(identifier)\""
                context.navigationLocations = locations
                context.isNavigationLocationsPresented = true
                context.isQuickOpenPresented = false
                context.isGlobalSearchPresented = false
                context.isCommandPalettePresented = false
                context.isGoToSymbolPresented = false
                context.isRenameSymbolPresented = false
            }
        }
    }

    private func registerFindReferencesCommand() {
        commandRegistry.register(command: .editorFindReferences) { _ in
            guard let root = context.workspace.currentDirectory?.standardizedFileURL else { return }

            guard let identifier = resolveWorkspaceIdentifier() else {
                context.lastError = "No symbol selected"
                return
            }

            let svc = WorkspaceNavigationService(codebaseIndexProvider: { context.codebaseIndex })
            let locations = await svc.findReferenceLocations(identifier: identifier, projectRoot: root, limit: 500)

            if locations.isEmpty {
                context.lastError = "No references found for \"\(identifier)\"."
                return
            }

            context.navigationLocationsTitle = "References for \"\(identifier)\""
            context.navigationLocations = locations
            context.isNavigationLocationsPresented = true
            context.isQuickOpenPresented = false
            context.isGlobalSearchPresented = false
            context.isCommandPalettePresented = false
            context.isGoToSymbolPresented = false
            context.isRenameSymbolPresented = false
        }
    }

    private func registerRenameSymbolCommand() {
        commandRegistry.register(command: .editorRenameSymbol) { _ in
            guard let identifier = resolveWorkspaceIdentifier() else {
                context.lastError = "No symbol selected"
                return
            }

            context.renameSymbolIdentifier = identifier
            context.isRenameSymbolPresented = true
            context.isNavigationLocationsPresented = false
            context.isQuickOpenPresented = false
            context.isGlobalSearchPresented = false
            context.isCommandPalettePresented = false
            context.isGoToSymbolPresented = false
        }
    }

    private func registerEditorStateCommands() {
        commandRegistry.register(command: .editorTabsCloseActive) { _ in
            context.fileEditor.closeActiveTab()
        }

        commandRegistry.register(command: .editorTabsCloseAll) { _ in
            context.fileEditor.closeAllTabs()
        }

        commandRegistry.register(command: .editorTabsNext) { _ in
            context.fileEditor.activateNextTab()
        }

        commandRegistry.register(command: .editorTabsPrevious) { _ in
            context.fileEditor.activatePreviousTab()
        }

        commandRegistry.register(command: .editorSplitRight) { _ in
            context.fileEditor.toggleSplit(axis: .vertical)
        }

        commandRegistry.register(command: .editorSplitDown) { _ in
            context.fileEditor.toggleSplit(axis: .horizontal)
        }

        commandRegistry.register(command: .editorFocusNextGroup) { _ in
            context.fileEditor.focusNextPane()
        }
    }

    private func registerTextFinderCommands() {
        commandRegistry.register(command: .editorFind) { _ in
            let item = NSMenuItem()
            item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
            NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
        }

        commandRegistry.register(command: .editorReplace) { _ in
            let item = NSMenuItem()
            item.tag = Int(NSTextFinder.Action.showReplaceInterface.rawValue)
            NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
        }

        commandRegistry.register(command: .editorToggleFold) { _ in
            NSApp.sendAction(#selector(CodeEditorTextView.toggleFoldAtCursor(_:)), to: nil, from: nil)
        }

        commandRegistry.register(command: .editorUnfoldAll) { _ in
            NSApp.sendAction(#selector(CodeEditorTextView.unfoldAll(_:)), to: nil, from: nil)
        }
    }

    private func registerMultiCursorCommands() {
        commandRegistry.register(command: .editorAddNextOccurrence) { _ in
            NSApp.sendAction(#selector(CodeEditorTextView.addNextOccurrence(_:)), to: nil, from: nil)
        }

        commandRegistry.register(command: .editorAddCursorAbove) { _ in
            NSApp.sendAction(#selector(CodeEditorTextView.addCursorAbove(_:)), to: nil, from: nil)
        }

        commandRegistry.register(command: .editorAddCursorBelow) { _ in
            NSApp.sendAction(#selector(CodeEditorTextView.addCursorBelow(_:)), to: nil, from: nil)
        }
    }

    private func registerInlineCompletionCommand() {
        commandRegistry.register(command: .editorTriggerInlineCompletion) { _ in
        }
    }

    private func registerInlineAIAssistCommand() {
        commandRegistry.register(command: .editorAIInlineAssist) { _ in
            context.ui.isAIChatVisible = true

            let pane = context.fileEditor.focusedPaneState
            let selectionContext = EditorAIContextBuilder.build(
                filePath: pane.selectedFile,
                language: pane.editorLanguage,
                buffer: pane.editorContent,
                selection: pane.selectedRange
            )

            let userPrompt = "Analyze this code and suggest improvements. " +
                "If there are any obvious bugs, point them out and propose fixes."
            context.conversationManager.currentInput = userPrompt
            context.conversationManager.sendMessage(context: selectionContext)
        }
    }

    private func registerViewCommands() {
        commandRegistry.register(command: .viewToggleMinimap) { _ in
            context.ui.toggleMinimap()
        }

        commandRegistry.register(command: .viewToggleMarkdownPreview) { _ in
            context.fileEditor.focusedPaneState.toggleMarkdownViewMode()
        }

        commandRegistry.register(command: .searchFindInWorkspace) { _ in
            context.isGlobalSearchPresented = true
            context.isQuickOpenPresented = false
        }

        commandRegistry.register(command: .viewToggleProblems) { _ in
            context.ui.isTerminalVisible = true
            context.ui.bottomPanelSelectedName = "Internal.Problems"
        }

        commandRegistry.register(command: .problemsNext) { _ in
            context.ui.isTerminalVisible = true
            context.ui.bottomPanelSelectedName = "Internal.Problems"
            if let diagnostic = context.diagnosticsStore.selectNext() {
                openDiagnostic(diagnostic)
            }
        }

        commandRegistry.register(command: .problemsPrevious) { _ in
            context.ui.isTerminalVisible = true
            context.ui.bottomPanelSelectedName = "Internal.Problems"
            if let diagnostic = context.diagnosticsStore.selectPrevious() {
                openDiagnostic(diagnostic)
            }
        }
    }

    private func registerWorkbenchCommands() {
        commandRegistry.register(command: .workbenchQuickOpen) { _ in
            context.isQuickOpenPresented = true
            context.isGlobalSearchPresented = false
            context.isCommandPalettePresented = false
            context.isGoToSymbolPresented = false
        }

        commandRegistry.register(command: .workbenchCommandPalette) { _ in
            context.isCommandPalettePresented = true
            context.isQuickOpenPresented = false
            context.isGlobalSearchPresented = false
            context.isGoToSymbolPresented = false
        }

        commandRegistry.register(command: .workbenchGoToSymbol) { _ in
            context.isGoToSymbolPresented = true
            context.isQuickOpenPresented = false
            context.isGlobalSearchPresented = false
            context.isCommandPalettePresented = false
        }
    }

    private func registerExplorerCommands() {
        registerExplorerOpenSelectionCommand()
        registerExplorerDeleteSelectionCommand()
        registerExplorerRenameSelectionCommand()
        registerExplorerRevealInFinderCommand()
    }

    private func registerExplorerOpenSelectionCommand() {
        commandRegistry.register(command: .explorerOpenSelection) { (args: ExplorerPathArgs) in
            let path = args.path
            guard let root = context.workspace.currentDirectory?.standardizedFileURL else { return }
            do {
                let url = try context.workspaceService.makePathValidator(projectRoot: root).validateAndResolve(path)
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if !isDirectory {
                    context.loadFile(from: url)
                }
            } catch {
                context.lastError = error.localizedDescription
            }
        }
    }

    private func registerExplorerDeleteSelectionCommand() {
        commandRegistry.register(command: .explorerDeleteSelection) { (args: ExplorerPathArgs) in
            let path = args.path
            guard let root = context.workspace.currentDirectory?.standardizedFileURL else { return }
            do {
                let url = try context.workspaceService.makePathValidator(projectRoot: root).validateAndResolve(path)
                await context.workspaceService.deleteItem(at: url)

                context.fileEditor.closeTab(filePath: url.path)
                context.workspace.removeOpenFile(url)
            } catch {
                context.lastError = error.localizedDescription
            }
        }
    }

    private func registerExplorerRenameSelectionCommand() {
        commandRegistry.register(command: .explorerRenameSelection) { (args: ExplorerRenameArgs) in
            let path = args.path
            let newName = args.newName
            guard let root = context.workspace.currentDirectory?.standardizedFileURL else { return }
            do {
                let url = try context.workspaceService.makePathValidator(projectRoot: root).validateAndResolve(path)

                if context.fileEditor.isFileOpenAndDirty(filePath: url.path) {
                    context.lastError = "Save changes before renaming an open file."
                    return
                }

                guard let newURL = await context.workspaceService.renameItem(at: url, to: newName) else { return }

                context.fileEditor.renameTab(oldPath: url.path, newPath: newURL.path)

                context.workspace.removeOpenFile(url)
                context.workspace.addOpenFile(newURL)
            } catch {
                context.lastError = error.localizedDescription
            }
        }
    }

    private func registerExplorerRevealInFinderCommand() {
        commandRegistry.register(command: .explorerRevealInFinder) { (args: ExplorerPathArgs) in
            let path = args.path
            guard let root = context.workspace.currentDirectory?.standardizedFileURL else { return }
            do {
                let url = try context.workspaceService.makePathValidator(projectRoot: root).validateAndResolve(path)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                context.lastError = error.localizedDescription
            }
        }
    }

    private func resolveWorkspaceIdentifier() -> String? {
        let selected = context.selectionContext.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if WorkspaceNavigationService.isValidIdentifier(selected) {
            return selected
        }

        let content = context.fileEditor.editorContent
        let cursor = context.fileEditor.selectedRange?.location ?? 0
        return WorkspaceNavigationService.identifierAtCursor(in: content, cursor: cursor)
    }

    @MainActor
    private func openWorkspaceLocation(_ loc: WorkspaceCodeLocation, projectRoot: URL) {
        do {
            let url = try context.workspaceService
                .makePathValidator(projectRoot: projectRoot)
                .validateAndResolve(loc.relativePath)
            context.loadFile(from: url)
            context.fileEditor.selectLine(loc.line)
        } catch {
            context.lastError = error.localizedDescription
        }
    }

    @MainActor
    private func openDiagnostic(_ diagnostic: Diagnostic) {
        guard let url = DiagnosticURLResolver.resolve(diagnostic, context: context) else { return }

        context.loadFile(from: url)
        context.fileEditor.selectLine(diagnostic.line)
    }
}
