import SwiftUI

struct AIChatPanel_Previews: PreviewProvider {
    static var previews: some View {
        let ctx = CodeSelectionContext()
        let container = DependencyContainer()
        return AIChatPanel(
            selectionContext: ctx,
            conversationManager: container.conversationManager,
            ui: UIStateManager(
                uiService: UIService(errorManager: ErrorManager(), eventBus: EventBus()),
                eventBus: EventBus()
            )
        )
    }
}
