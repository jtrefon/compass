import SwiftUI

@MainActor
struct CoreUIRegistrar<Context: IDEContext & ObservableObject> {
    let registry: UIRegistry
    let context: Context

    func registerAll() {
        _ = context.diagnosticsStore
        registerSidebarComponents()
        registerBottomPanelComponents()
        registerRightPanelComponents()
    }

    private func registerSidebarComponents() {
        registry.register(
            point: .sidebarLeft,
            name: "Internal.FileExplorer",
            icon: "folder",
            view: FileExplorerView(context: context)
        )
    }

    private func registerBottomPanelComponents() {
        registry.register(
            point: .panelBottom,
            name: AppConstants.Overlay.internalTerminalPanelName,
            icon: "terminal",
            makeView: {
                NativeTerminalView(
                    currentDirectory: Binding(
                        get: { context.workspace.currentDirectory },
                        set: { _ in }
                    ),
                    ui: context.ui,
                    eventBus: context.eventBus
                )
            }
        )

        registry.register(
            point: .panelBottom,
            name: "Internal.Logs",
            icon: "doc.text.magnifyingglass",
            view: LogsPanelView(
                ui: context.ui,
                projectRoot: context.workspace.currentDirectory,
                eventBus: context.eventBus
            )
        )

        registry.register(
            point: .panelBottom,
            name: "Internal.Problems",
            icon: "exclamationmark.triangle",
            view: ProblemsView(store: context.diagnosticsStore, context: context)
        )
    }

    private func registerRightPanelComponents() {
        registry.register(
            point: .panelRight,
            name: "Internal.AIChat",
            icon: "sparkles",
            view: AIChatPanel(
                selectionContext: context.selectionContext,
                conversationManager: context.conversationManager,
                ui: context.ui
            )
        )
    }
}
