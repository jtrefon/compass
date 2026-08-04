import SwiftUI

struct NativeTerminalView_Previews: PreviewProvider {
    static var previews: some View {
        NativeTerminalView(
            currentDirectory: .constant(nil),
            ui: UIStateManager(
                uiService: UIService(errorManager: ErrorManager(), eventBus: EventBus()),
                eventBus: EventBus()
            ),
            eventBus: EventBus()
        )
        .frame(width: 600, height: 400)
    }
}
