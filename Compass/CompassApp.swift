//
//  CompassApp.swift
//  Compass
//
//  Created by Jack Trefon on 25/08/2025.
//

import SwiftUI
import AppKit

fileprivate func earlyDiag(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    let fm = FileManager.default
    let tmpLog = URL(fileURLWithPath: "/tmp/Compass-startup.log")
    if let data = line.data(using: .utf8) {
        if fm.fileExists(atPath: tmpLog.path) {
            if let handle = try? FileHandle(forWritingTo: tmpLog) {
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
                _ = try? handle.close()
            }
        } else {
            try? data.write(to: tmpLog)
        }
    }
    Swift.print("[EARLY-DIAG] \(msg)")
    fflush(stdout)
}

@main
struct CompassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let launchContext: AppLaunchContext
    private let isUnitTesting: Bool
    @ObservedObject private var container: DependencyContainer
    @StateObject private var appState: AppState
    @StateObject private var errorManager: ErrorManager
    @AppStorage(AppConstants.Storage.codebaseIndexEnabledKey, store: AppRuntimeEnvironment.userDefaults)
    private var codebaseIndexEnabled: Bool = true
    init() {
        let _initStart = Date()
        earlyDiag("CompassApp.init START")
        
        Task { await DiagnosticsLogger.shared.logEvent(.appInitStart, name: "CompassApp.init") }
        
        let launchContext = AppRuntimeEnvironment.launchContext
        self.launchContext = launchContext
        let isUnitTesting = launchContext.mode == .unitTest
        self.isUnitTesting = isUnitTesting
        earlyDiag("launchMode=\(launchContext.mode) isUnitTesting=\(isUnitTesting)")

        Task { await DiagnosticsLogger.shared.logEvent(.dependencyContainerInitStart, name: "DependencyContainer") }
        earlyDiag("About to create DependencyContainer...")
        
        let container = DependencyContainer(launchContext: launchContext)
        
        earlyDiag("DependencyContainer created")
        
        Task { await DiagnosticsLogger.shared.logEvent(.dependencyContainerInitEnd, name: "DependencyContainer", metadata: ["durationMs": String(format: "%.2f", Date().timeIntervalSince(_initStart) * 1000)]) }
        
        self.container = container

        earlyDiag("Getting errorManager...")
        let errorMgr = container.errorManager as? ErrorManager ?? ErrorManager()
        earlyDiag("Creating AppState...")
        let appSt = container.makeAppState()
        earlyDiag("AppState created")

        if launchContext.isUITesting {
            appSt.ui.isSidebarVisible = true
            appSt.ui.isTerminalVisible = true
            appSt.ui.isAIChatVisible = true
            appSt.ui.isCodePanelVisible = true
            appSt.ui.bottomPanelSelectedName = AppConstants.Overlay.internalTerminalPanelName
        }

        if launchContext.isUITesting {
            UITestScenarioBootstrapper.bootstrapIfNeeded(appState: appSt, launchContext: launchContext)
        }

        self._errorManager = StateObject(wrappedValue: errorMgr)
        self._appState = StateObject(wrappedValue: appSt)
        AppDelegate.sharedAppState = appSt
        AppDelegate.sharedErrorManager = errorMgr
        AppDelegate.sharedContainer = container
        
        earlyDiag("CompassApp.init END")
        
        Task { await DiagnosticsLogger.shared.logEvent(.appInitEnd, name: "CompassApp.init", metadata: ["totalDurationMs": String(format: "%.2f", Date().timeIntervalSince(_initStart) * 1000)]) }
    }

    var body: some Scene {
        Window("Compass", id: "main") {
            if launchContext.mode == .unitTest {
                Color.clear.frame(width: 0, height: 0)
            } else {
                AppRootView(
                    appState: appState,
                    errorManager: errorManager,
                    isContainerInitialized: container.isInitialized,
                    initializationStatus: container.initializationStatus
                )
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            if !isUnitTesting {
            CommandGroup(replacing: .newItem) {
                Button(localized("menu.new_project")) {
                    Task { try? await appState.commandRegistry.execute(.projectNew) }
                }
                .keyboardShortcut("n", modifiers: [.command])
            }

            CommandGroup(after: .importExport) {
                Button(localized("menu.open")) {
                    Task { try? await appState.commandRegistry.execute(.fileOpen) }
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button(localized("menu.open_folder")) {
                    Task { try? await appState.commandRegistry.execute(.fileOpenFolder) }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button(localized("menu.save")) {
                    Task { try? await appState.commandRegistry.execute(.fileSave) }
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button(localized("menu.save_as")) {
                    Task { try? await appState.commandRegistry.execute(.fileSaveAs) }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandGroup(after: .sidebar) {
                Toggle(localized("menu.toggle.file_explorer"), isOn: Binding(
                    get: { appState.ui.isSidebarVisible },
                    set: { appState.ui.isSidebarVisible = $0 }
                ))

                Toggle(localized("menu.toggle.terminal"), isOn: Binding(
                    get: { appState.ui.isTerminalVisible },
                    set: { appState.ui.isTerminalVisible = $0 }
                ))

                Toggle(localized("menu.toggle.ai_chat"), isOn: Binding(
                    get: { appState.ui.isAIChatVisible },
                    set: { appState.ui.isAIChatVisible = $0 }
                ))

                Toggle(localized("menu.toggle.code_panel"), isOn: Binding(
                    get: { appState.ui.isCodePanelVisible },
                    set: { appState.ui.isCodePanelVisible = $0 }
                ))

                Divider()

                Toggle(localized("menu.toggle.hidden_files"), isOn: Binding(
                    get: { appState.showHiddenFilesInFileTree },
                    set: { appState.showHiddenFilesInFileTree = $0 }
                ))
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Divider()

                Toggle(localized("menu.toggle.markdown_view"), isOn: Binding(
                    get: { appState.fileEditor.focusedPaneState.markdownViewMode },
                    set: { appState.fileEditor.focusedPaneState.markdownViewMode = $0 }
                ))
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            CommandMenu(localized("menu.tools")) {
                // AI Mode Toggle
                Menu("AI Mode") {
                    ForEach(AIMode.allCases, id: \.self) { mode in
                        Button(mode.rawValue) {
                            appState.conversationManager.currentMode = mode
                        }
                        .help(mode.description)
                    }
                }
                
                Divider()
                
                Toggle(localized("menu.tools.codebase_index_enabled"), isOn: $codebaseIndexEnabled)
                    .onChange(of: codebaseIndexEnabled) { _, newValue in
                        appState.setCodebaseIndexEnabled(newValue)
                    }

                Divider()

                Button(localized("menu.tools.format_document")) {
                    Task { try? await appState.commandRegistry.execute(.editorFormat) }
                }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])

                Button(localized("menu.tools.reindex_project_now")) {
                    appState.reindexProjectNow()
                }

                Button(localized("menu.tools.rebuild_vector_store")) {
                    appState.rebuildVectorStore()
                }
            }

            CommandMenu(localized("menu.editor")) {
                Button(localized("menu.editor.find")) {
                    Task { try? await appState.commandRegistry.execute(.editorFind) }
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button(localized("menu.editor.replace")) {
                    Task { try? await appState.commandRegistry.execute(.editorReplace) }
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Divider()

                Button(localized("menu.editor.trigger_inline_completion")) {
                    Task { try? await appState.commandRegistry.execute(.editorTriggerInlineCompletion) }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button(localized("menu.editor.ai_inline_assist")) {
                    Task { try? await appState.commandRegistry.execute(.editorAIInlineAssist) }
                }
                .keyboardShortcut("i", modifiers: [.command])

                Divider()

                Button(localized("menu.editor.close_tab")) {
                    Task { try? await appState.commandRegistry.execute(.editorTabsCloseActive) }
                }
                .keyboardShortcut("w", modifiers: [.command])

                Button(localized("menu.editor.close_all_tabs")) {
                    Task { try? await appState.commandRegistry.execute(.editorTabsCloseAll) }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Button(localized("menu.editor.next_tab")) {
                    Task { try? await appState.commandRegistry.execute(.editorTabsNext) }
                }
                .keyboardShortcut(.tab, modifiers: [.control])

                Button(localized("menu.editor.previous_tab")) {
                    Task { try? await appState.commandRegistry.execute(.editorTabsPrevious) }
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

                Divider()

                Button(localized("menu.editor.split_right")) {
                    Task { try? await appState.commandRegistry.execute(.editorSplitRight) }
                }
                .keyboardShortcut("\\", modifiers: [.command])

                Button(localized("menu.editor.split_down")) {
                    Task { try? await appState.commandRegistry.execute(.editorSplitDown) }
                }

                Button(localized("menu.editor.focus_next_group")) {
                    Task { try? await appState.commandRegistry.execute(.editorFocusNextGroup) }
                }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
            }

            CommandMenu(localized("menu.search")) {
                Button(localized("menu.search.find_in_workspace")) {
                    Task { try? await appState.commandRegistry.execute(.searchFindInWorkspace) }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button(localized("menu.search.command_palette")) {
                    Task { try? await appState.commandRegistry.execute(.workbenchCommandPalette) }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            CommandMenu(localized("menu.go")) {
                Button(localized("menu.go.quick_open")) {
                    Task { try? await appState.commandRegistry.execute(.workbenchQuickOpen) }
                }
                .keyboardShortcut("p", modifiers: [.command])

                Button(localized("menu.go.go_to_symbol")) {
                    Task { try? await appState.commandRegistry.execute(.workbenchGoToSymbol) }
                }
                .keyboardShortcut("t", modifiers: [.command])

                Divider()

                Button(localized("menu.go.go_to_definition")) {
                    Task { try? await appState.commandRegistry.execute(.editorGoToDefinition) }
                }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: [])

                Button(localized("menu.go.find_references")) {
                    Task { try? await appState.commandRegistry.execute(.editorFindReferences) }
                }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: [.shift])

                Button(localized("menu.go.rename_symbol")) {
                    Task { try? await appState.commandRegistry.execute(.editorRenameSymbol) }
                }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), modifiers: [])

                Divider()

                Button(localized("menu.go.add_next_occurrence")) {
                    Task { try? await appState.commandRegistry.execute(.editorAddNextOccurrence) }
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button(localized("menu.go.add_cursor_above")) {
                    Task { try? await appState.commandRegistry.execute(.editorAddCursorAbove) }
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(UnicodeScalar(NSUpArrowFunctionKey)!)),
                    modifiers: [.command, .option]
                )

                Button(localized("menu.go.add_cursor_below")) {
                    Task { try? await appState.commandRegistry.execute(.editorAddCursorBelow) }
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
                    modifiers: [.command, .option]
                )
            }

            CommandMenu(localized("menu.explorer")) {
                Button(localized("menu.explorer.delete"), action: {
                    guard let url = appState.selectedFileTreeURL() else { return }
                    Task {
                        try? await appState.commandRegistry.execute(
                            .explorerDeleteSelection,
                            args: ExplorerPathArgs(path: url.path)
                        )
                    }
                })
                .keyboardShortcut(.delete, modifiers: [.command])

                Button(localized("menu.explorer.rename"), action: {
                    guard let url = appState.selectedFileTreeURL() else { return }
                    let alert = NSAlert()
                    alert.messageText = localized("file_tree.rename.title")
                    alert.informativeText = localized("file_tree.rename.info")
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: localized("file_tree.rename.button"))
                    alert.addButton(withTitle: localized("common.cancel"))
                    let textField = NSTextField(string: url.lastPathComponent)
                    textField.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
                    alert.accessoryView = textField
                    let response = alert.runModal()
                    guard response == .alertFirstButtonReturn else { return }
                    let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !newName.isEmpty else { return }
                    Task {
                        try? await appState.commandRegistry.execute(
                            .explorerRenameSelection,
                            args: ExplorerRenameArgs(path: url.path, newName: newName)
                        )
                    }
                })

                Button(localized("file_tree.context.show_in_finder"), action: {
                    guard let url = appState.selectedFileTreeURL() else { return }
                    Task {
                        try? await appState.commandRegistry.execute(
                            .explorerRevealInFinder,
                            args: ExplorerPathArgs(path: url.path)
                        )
                    }
                })
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            }
        }
        .windowResizability(.automatic)

        Settings {
            if isUnitTesting {
                EmptyView()
            } else {
                SettingsView(ui: appState.ui)
            }
        }
    }
}

private struct AppRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var errorManager: ErrorManager
    let isContainerInitialized: Bool
    let initializationStatus: String
    @State private var didInitializeCorePlugin: Bool = false

    var body: some View {
        ZStack {
            ContentView(appState: appState)
                .environmentObject(errorManager)
                .onAppear {
                    if AppRuntimeEnvironment.launchContext.isUITesting {
                        appState.ui.isSidebarVisible = true
                        appState.ui.isTerminalVisible = true
                        appState.ui.isAIChatVisible = true
                        appState.ui.isCodePanelVisible = true
                        appState.ui.bottomPanelSelectedName = AppConstants.Overlay.internalTerminalPanelName
                    }
                    NSApp.activate(ignoringOtherApps: true)
                }
                .task {
                    if AppRuntimeEnvironment.launchContext.isUITesting {
                        appState.ui.isSidebarVisible = true
                        appState.ui.isTerminalVisible = true
                        appState.ui.isAIChatVisible = true
                        appState.ui.isCodePanelVisible = true
                        appState.ui.bottomPanelSelectedName = AppConstants.Overlay.internalTerminalPanelName
                    }
                    UICompositionRoot.compose(
                        appState: appState,
                        didInitializeCorePlugin: &didInitializeCorePlugin
                    )
                }
                .alert(localized("alert.error.title"), isPresented: $errorManager.showErrorAlert) {
                    Button(localized("common.ok")) {
                        errorManager.dismissError()
                    }
                } message: {
                    if let error = errorManager.currentError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error.localizedDescription)
                                .font(.headline)

                            if let suggestion = error.recoverySuggestion {
                                Text(String(format: localized("alert.suggestion_format"), suggestion))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

            Text(appState.isUIReady ? "ready" : "not_ready")
                .font(.caption2)
                .opacity(0.01)
                // The marker exists for UI-test polling — never expose it to VoiceOver.
                .accessibilityHidden(true)
                .accessibilityIdentifier(AccessibilityID.appReadyMarker)
                .accessibilityValue(appState.isUIReady ? "ready" : "not_ready")
                .allowsHitTesting(false)

            if !isContainerInitialized {
                LoadingOverlayView(status: initializationStatus)
            }
        }

    }
}

/// Loading overlay shown while services initialize
private struct LoadingOverlayView: View {
    let status: String
    
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Initializing...")
                .font(.headline)
            
            Text(status)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(32)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: AppConstants.Layout.cornerLg))
        .shadow(radius: 10)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    fileprivate static weak var sharedAppState: AppState?
    fileprivate static weak var sharedErrorManager: ErrorManager?
    fileprivate static weak var sharedContainer: DependencyContainer?
    fileprivate static var uiTestFallbackWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchMode = AppRuntimeEnvironment.launchContext.mode
        earlyDiag("AppDelegate.applicationDidFinishLaunching launchMode=\(launchMode)")
        let isUnitTesting = launchMode == .unitTest
        if isUnitTesting {
            NSApp.setActivationPolicy(.accessory)
            earlyDiag("AppDelegate configured accessory activation policy for unit-test mode")
            return
        }

        guard launchMode == .uiTest else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            earlyDiag("uiTest activationPolicy(before)=\(NSApp.activationPolicy().rawValue)")
            _ = NSApp.setActivationPolicy(.regular)
            earlyDiag("uiTest activationPolicy(after)=\(NSApp.activationPolicy().rawValue)")
            NSApp.activate(ignoringOtherApps: true)
            earlyDiag("uiTest window bootstrap count=\(NSApp.windows.count)")
            guard NSApp.windows.isEmpty else { return }

            guard let appState = Self.sharedAppState, let errorManager = Self.sharedErrorManager else {
                earlyDiag("uiTest fallback window skipped: missing shared app state")
                return
            }

            let rootView = AppRootView(
                appState: appState,
                errorManager: errorManager,
                isContainerInitialized: true,
                initializationStatus: ""
            )
            let hosting = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hosting)
            window.styleMask.insert(.resizable)
            window.title = "Compass"
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                window.minSize = UILayoutNormalizer.normalizedMinWindowSize(screenVisibleFrame: visible)
                let defaultFrame = UILayoutNormalizer.normalizedDefaultWindowFrame(screenVisibleFrame: visible)
                window.setFrame(defaultFrame, display: true)
            } else {
                window.minSize = NSSize(width: 700, height: 480)
                window.setContentSize(NSSize(width: 1280, height: 800))
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Self.uiTestFallbackWindow = window
            earlyDiag("uiTest fallback window created. windows=\(NSApp.windows.count)")
        }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        Self.sharedAppState?.persistSessionNow()
        Self.sharedContainer?.persistVectorStore()
    }
}
