//
//  ContentView.swift
//  Compass
//
//  Created by Jack Trefon on 25/08/2025.
//

import SwiftUI
import AppKit

struct ContentView: View {

    // MARK: - Properties

    @ObservedObject var appState: AppState
    @ObservedObject private var fileEditor: FileEditorStateManager
    @ObservedObject private var workspace: WorkspaceStateManager
    @ObservedObject private var uiState: UIStateManager
    @ObservedObject private var registry: UIRegistry

    @State private var logsFollow: Bool = true
    @State private var logsSource: String = LogsPanelView.LogSource.app.rawValue
    @State private var dragSidebarWidth: Double?
    @State private var dragChatWidth: Double?
    @State private var dragWindowWidth: CGFloat = 0

    init(appState: AppState) {
        self.appState = appState
        self._fileEditor = ObservedObject(wrappedValue: appState.fileEditor)
        self._workspace = ObservedObject(wrappedValue: appState.workspace)
        self._uiState = ObservedObject(wrappedValue: appState.ui)
        self._registry = ObservedObject(wrappedValue: appState.uiRegistry)
    }

    // MARK: - Body & Root

    var body: some View {
        let _ = trackViewRender("ContentView.body")
        return rootView
    }

    private var rootView: some View {
        let _ = trackViewRender("ContentView.rootView")
        return ZStack {
            mainLayout
        }
        .nativeGlassBackground(.panel, cornerRadius: 0)
        .environment(\.font, .system(size: CGFloat(uiState.fontSize)))
        .preferredColorScheme(appState.selectedTheme.colorScheme)
        .accessibilityIdentifier(AccessibilityID.appRootView)
        .accessibilityValue("theme=\(appState.selectedTheme.rawValue)")
        .sheet(isPresented: $appState.isGlobalSearchPresented) {
            GlobalSearchOverlayView(appState: appState, isPresented: $appState.isGlobalSearchPresented)
        }
        .sheet(isPresented: $appState.isQuickOpenPresented) {
            QuickOpenOverlayView(appState: appState, isPresented: $appState.isQuickOpenPresented)
        }
        .popover(isPresented: $appState.isCommandPalettePresented) {
            CommandPaletteOverlayView(
                commandRegistry: appState.commandRegistry,
                isPresented: $appState.isCommandPalettePresented
            )
        }
        .sheet(isPresented: $appState.isGoToSymbolPresented) {
            GoToSymbolOverlayView(appState: appState, isPresented: $appState.isGoToSymbolPresented)
        }
        .sheet(isPresented: $appState.isNavigationLocationsPresented) {
            NavigationLocationsOverlayView(
                appState: appState,
                isPresented: $appState.isNavigationLocationsPresented
            )
        }
        .sheet(isPresented: $appState.isRenameSymbolPresented) {
            RenameSymbolOverlayView(appState: appState, isPresented: $appState.isRenameSymbolPresented)
        }
    }

    private var mainLayout: some View {
        let _ = trackViewRender("ContentView.mainLayout")
        return VStack(spacing: 0) {
            WindowSetupView(appState: appState)
            workspaceLayout
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            IndexStatusBarView(
                appState: appState,
                codebaseIndexProvider: { appState.codebaseIndex },
                vectorStoreProvider: { appState.vectorStoreService },
                eventBus: appState.eventBus,
                refreshRemoteAIAccountBalance: appState.refreshRemoteAIAccountBalance
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Layout: Workspace

    private var workspaceLayout: some View {
        GeometryReader { proxy in
            let sidebarW = dragSidebarWidth ?? uiState.sidebarWidth
            let chatW = dragChatWidth ?? uiState.chatPanelWidth
            HStack(spacing: 0) {
                if uiState.isSidebarVisible, let pluginView = registry.views(for: .sidebarLeft).first {
                    pluginView.makeView()
                        .frame(width: sidebarW)
                        .frame(maxHeight: .infinity)
                        .accessibilityIdentifier(AccessibilityID.leftSidebarPanel)

                    PanelDivider(orientation: .vertical) {
                        if dragSidebarWidth == nil {
                            dragSidebarWidth = uiState.sidebarWidth
                            dragWindowWidth = proxy.size.width
                        }
                        let proposed = (dragSidebarWidth ?? uiState.sidebarWidth) + $0.translation.width
                        dragSidebarWidth = UILayoutNormalizer.normalizeSidebarWidth(proposed, windowWidth: dragWindowWidth)
                    } onEnded: {
                        if let w = dragSidebarWidth {
                            uiState.updateSidebarWidth(w)
                        }
                        dragSidebarWidth = nil
                    }
                    .accessibilityIdentifier(AccessibilityID.sidebarResizeHandle)
                }

                HStack(spacing: 0) {
                    editorAndTerminal

                    if uiState.isAIChatVisible, let pluginView = registry.views(for: .panelRight).first {
                        PanelDivider(orientation: .vertical) {
                            if dragChatWidth == nil {
                                dragChatWidth = uiState.chatPanelWidth
                                dragWindowWidth = proxy.size.width
                            }
                            let proposed = (dragChatWidth ?? uiState.chatPanelWidth) - $0.translation.width
                            dragChatWidth = UILayoutNormalizer.normalizeChatPanelWidth(proposed, windowWidth: dragWindowWidth)
                        } onEnded: {
                            if let w = dragChatWidth {
                                uiState.updateChatPanelWidth(w)
                            }
                            dragChatWidth = nil
                        }
                        .accessibilityIdentifier(AccessibilityID.chatResizeHandle)

                        pluginView.makeView()
                            .frame(width: chatW)
                            .frame(maxHeight: .infinity)
                            .accessibilityIdentifier(AccessibilityID.rightChatPanel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onAppear {
                applyHorizontalPanelWidths(proposedSidebarWidth: uiState.sidebarWidth, proposedChatWidth: uiState.chatPanelWidth, windowWidth: proxy.size.width)
            }
            .onChange(of: proxy.size.width) { oldWidth, newWidth in
                guard abs(newWidth - oldWidth) > 2, dragSidebarWidth == nil, dragChatWidth == nil else { return }
                applyHorizontalPanelWidths(proposedSidebarWidth: uiState.sidebarWidth, proposedChatWidth: uiState.chatPanelWidth, windowWidth: newWidth)
            }
        }
    }

    private func applyHorizontalPanelWidths(
        proposedSidebarWidth: Double,
        proposedChatWidth: Double,
        windowWidth: CGFloat
    ) {
        if uiState.isSidebarVisible {
            let clamped = UILayoutNormalizer.normalizeSidebarWidth(proposedSidebarWidth, windowWidth: windowWidth)
            if abs(uiState.sidebarWidth - clamped) > 0.5 {
                uiState.updateSidebarWidth(clamped)
            }
        }
        if uiState.isAIChatVisible {
            let clamped = UILayoutNormalizer.normalizeChatPanelWidth(proposedChatWidth, windowWidth: windowWidth)
            if abs(uiState.chatPanelWidth - clamped) > 0.5 {
                uiState.updateChatPanelWidth(clamped)
            }
        }
    }

    // MARK: - Layout: Editor & Terminal

    @ViewBuilder
    private var editorAndTerminal: some View {
        if uiState.isCodePanelVisible || uiState.isTerminalVisible {
            EditorTerminalSplitView(
                isCodePanelVisible: uiState.isCodePanelVisible,
                isTerminalVisible: uiState.isTerminalVisible,
                terminalHeight: uiState.terminalHeight,
                setTerminalHeight: { uiState.updateTerminalHeight($0) },
                editor: { editorArea },
                terminal: { terminalPanel }
            )
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var editorArea: some View {
        if fileEditor.isSplitEditor {
            if fileEditor.splitAxis == .vertical {
                HSplitView {
                    editorPane(.primary)
                    editorPane(.secondary)
                }
            } else {
                VSplitView {
                    editorPane(.primary)
                    editorPane(.secondary)
                }
            }
        } else {
            EditorPaneView(
                paneID: .primary,
                pane: fileEditor.primaryPane,
                isFocused: true,
                onFocus: { fileEditor.focus(.primary) },
                selectionContext: appState.selectionContext,
                lineCompletionEngine: appState.lineCompletionEngine,
                inlineCompletionDebugOverlayEnabled: uiState.inlineCompletionDebugOverlayEnabled,
                showLineNumbers: uiState.showLineNumbers,
                wordWrap: uiState.wordWrap,
                minimapVisible: uiState.minimapVisible,
                fontSize: uiState.fontSize,
                fontFamily: uiState.fontFamily
            )
        }
    }

    private func editorPane(_ pane: FileEditorStateManager.PaneID) -> some View {
        let manager = (pane == .primary) ? fileEditor.primaryPane : fileEditor.secondaryPane
        let focused = (pane == .primary) ? fileEditor.focusedPane == .primary : fileEditor.focusedPane == .secondary

        return EditorPaneView(
            paneID: pane,
            pane: manager,
            isFocused: focused,
            onFocus: { fileEditor.focus(pane) },
            selectionContext: appState.selectionContext,
            lineCompletionEngine: appState.lineCompletionEngine,
            inlineCompletionDebugOverlayEnabled: uiState.inlineCompletionDebugOverlayEnabled,
            showLineNumbers: uiState.showLineNumbers,
            wordWrap: uiState.wordWrap,
            minimapVisible: uiState.minimapVisible,
            fontSize: uiState.fontSize,
            fontFamily: uiState.fontFamily
        )
    }

    // MARK: - Layout: Bottom Panel

    @ViewBuilder
    private var terminalPanel: some View {
        let bottomViews = registry.views(for: .panelBottom)

        if bottomViews.count == 1, let pluginView = bottomViews.first {
            pluginView.makeView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .nativeGlassBackground(.panel, cornerRadius: 0)
                .frame(minHeight: 100)
        } else if bottomViews.count > 1 {
            let selectedName = uiState.bottomPanelSelectedName
            let selectedView = bottomViews.first(where: { $0.name == selectedName }) ?? bottomViews[0]

            VStack(spacing: 0) {
                bottomPanelHeader(selectedName: selectedName, bottomViews: bottomViews)
                selectedView.makeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .nativeGlassBackground(.panel, cornerRadius: 0)
            .frame(minHeight: 100)
        }
    }

    private func bottomPanelHeader(selectedName: String, bottomViews: [PluginView]) -> some View {
        HStack(spacing: AppConstants.Layout.spacingSm) {
            bottomPanelLeadingControls(selectedName: selectedName)

            Spacer(minLength: 0)

            Picker(localized("bottom_panel.picker"), selection: $uiState.bottomPanelSelectedName) {
                ForEach(bottomViews) { view in
                    Text(view.displayName)
                        .tag(view.name)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: uiState.bottomPanelSelectedName) { _, newName in
                Task { appState.uiService.setBottomPanelSelectedName(newName) }
            }
            .labelsHidden()
            .frame(maxWidth: 360)

            Spacer(minLength: 0)

            bottomPanelTrailingControls(selectedName: selectedName)
        }
        .padding(.horizontal, AppConstants.Layout.spacingSm)
        .padding(.vertical, AppConstants.Layout.spacingXS)
        .frame(height: AppConstants.Layout.headerHeight)
        .nativeGlassBackground(.header, cornerRadius: 0)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppConstants.Color.separatorDefault)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func bottomPanelLeadingControls(selectedName: String) -> some View {
        if selectedName == AppConstants.Overlay.internalTerminalPanelName {
            Button(
                action: {
                    appState.eventBus.publish(TerminalClearRequestedEvent())
                },
                label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            )
            .buttonStyle(.borderless)
            .help(localized("terminal.clear_help"))

            Text(localized("bottom_panel.terminal"))
                .font(.system(size: max(10, uiState.fontSize - 2), weight: .medium))
        } else if selectedName == "Internal.Logs" {
            Text(localized("bottom_panel.logs"))
                .font(.system(size: max(10, uiState.fontSize - 2), weight: .medium))
        } else if selectedName == "Internal.Problems" {
            Text(localized("bottom_panel.problems"))
                .font(.system(size: max(10, uiState.fontSize - 2), weight: .medium))
        }
    }

    @ViewBuilder
    private func bottomPanelTrailingControls(selectedName: String) -> some View {
        if selectedName == AppConstants.Overlay.internalTerminalPanelName {
            Text(workspace.currentDirectory?.lastPathComponent ?? localized("bottom_panel.terminal"))
                .font(.system(size: max(10, uiState.fontSize - 3)))
                .foregroundColor(.secondary)
                .lineLimit(1)
        } else if selectedName == "Internal.Logs" {
            Toggle(localized("logs.follow"), isOn: $logsFollow)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: logsFollow) { _, newValue in
                    appState.eventBus.publish(LogsFollowChangedEvent(follow: newValue))
                }

            Picker(localized("logs.source"), selection: $logsSource) {
                ForEach(LogsPanelView.LogSource.allCases) { src in
                    Text(src.title).tag(src.rawValue)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: logsSource) { _, newValue in
                appState.eventBus.publish(LogsSourceChangedEvent(sourceRawValue: newValue))
            }

            Button(localized("common.clear")) {
                appState.eventBus.publish(LogsClearRequestedEvent())
            }
            .buttonStyle(.borderless)
        } else if selectedName == "Internal.Problems" {
            Button(localized("common.clear")) {
                appState.eventBus.publish(ProblemsClearRequestedEvent())
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Private: EditorTerminalSplitView

private struct EditorTerminalSplitView<Editor: View, Terminal: View>: View {
    let isCodePanelVisible: Bool
    let isTerminalVisible: Bool
    let terminalHeight: Double
    let setTerminalHeight: (Double) -> Void
    let editor: () -> Editor
    let terminal: () -> Terminal

    @State private var dragStartTerminalHeight: Double?
    @State private var isDividerHovered = false

    var body: some View {
        GeometryReader { proxy in
            let containerHeight = proxy.size.height
            let minEditorHeight = Double(AppConstants.Layout.minTerminalHeight)
            let maxAllowedTerminal = max(AppConstants.Layout.minTerminalHeight, containerHeight - minEditorHeight - 2)

            VStack(spacing: 0) {
                if isCodePanelVisible {
                    editor()
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: .infinity)
                }

                if isTerminalVisible {
                    Color.clear
                        .frame(height: AppConstants.Layout.panelDividerHitWidth)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            isDividerHovered = hovering
                            if hovering {
                                NSCursor.resizeUpDown.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 3)
                                .onChanged { value in
                                    if dragStartTerminalHeight == nil {
                                        dragStartTerminalHeight = terminalHeight
                                    }

                                    let start = dragStartTerminalHeight ?? terminalHeight
                                    let proposed = start - value.translation.height
                                    let clamped = max(
                                        AppConstants.Layout.minTerminalHeight,
                                        min(maxAllowedTerminal, proposed)
                                    )
                                    setTerminalHeight(clamped)
                                }
                                .onEnded { _ in
                                    dragStartTerminalHeight = nil
                                }
                        )
                        .overlay(alignment: .center) {
                            Rectangle()
                                .fill(isDividerHovered
                                    ? AppConstants.Color.dividerHover
                                    : AppConstants.Color.separatorSubtle)
                                .frame(height: isDividerHovered
                                    ? AppConstants.Layout.panelDividerHoverThickness
                                    : AppConstants.Layout.panelDividerVisibleThickness)
                                .animation(.easeInOut(duration: 0.15), value: isDividerHovered)
                        }

                    terminal()
                        .frame(maxWidth: .infinity)
                        .frame(height: terminalHeight)
                }
            }
        }
    }
}

// MARK: - Private: PanelDivider

private struct PanelDivider: View {
    let orientation: Orientation
    let onChanged: (DragGesture.Value) -> Void
    let onEnded: () -> Void

    @State private var isHovered = false

    enum Orientation {
        case vertical
        case horizontal
    }

    var body: some View {
        Color.clear
            .frame(width: orientation == .vertical ? AppConstants.Layout.panelDividerHitWidth : nil)
            .frame(height: orientation == .horizontal ? AppConstants.Layout.panelDividerHitWidth : nil)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    (orientation == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged(onChanged)
                    .onEnded { _ in onEnded() }
            )
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(isHovered
                        ? AppConstants.Color.dividerHover
                        : AppConstants.Color.separatorSubtle)
                    .frame(width: orientation == .vertical
                        ? (isHovered ? AppConstants.Layout.panelDividerHoverThickness : AppConstants.Layout.panelDividerVisibleThickness)
                        : nil)
                    .frame(height: orientation == .horizontal
                        ? (isHovered ? AppConstants.Layout.panelDividerHoverThickness : AppConstants.Layout.panelDividerVisibleThickness)
                        : nil)
            }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Private: WindowSetupView

private struct WindowSetupView: View {
    @ObservedObject var appState: AppState
    @Environment(\.nsWindow) private var nsWindow: NSWindow?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .background(WindowCaptureView { window in
                appState.windowProvider.setWindow(window)
                appState.attachWindow(window)
                window.title = appState.workspace.currentDirectory?.lastPathComponent ?? "Compass"

                guard let screen = window.screen ?? NSScreen.main else { return }
                let visibleFrame = screen.visibleFrame
                window.minSize = UILayoutNormalizer.normalizedMinWindowSize(screenVisibleFrame: visibleFrame)

                var targetFrame = window.frame
                if targetFrame.width <= 1 || targetFrame.height <= 1 {
                    targetFrame = UILayoutNormalizer.normalizedDefaultWindowFrame(screenVisibleFrame: visibleFrame)
                }
                let normalized = UILayoutNormalizer.normalizeWindowFrame(targetFrame, screenVisibleFrame: visibleFrame)
                if normalized != window.frame {
                    window.setFrame(normalized, display: true)
                }
            })
            .onReceive(appState.workspace.$currentDirectory) { newDirectory in
                nsWindow?.title = newDirectory?.lastPathComponent ?? "Compass"
            }
    }
}

// MARK: - Previews

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(appState: DependencyContainer().makeAppState())
    }
}
