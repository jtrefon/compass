import Foundation
import SwiftUI

@MainActor
protocol IDEContext: AnyObject {
    var fileEditor: FileEditorStateManager { get }
    var workspace: WorkspaceStateManager { get }
    var ui: UIStateManager { get }

    var eventBus: EventBusProtocol { get }
    var commandRegistry: CommandRegistry { get }
    var uiRegistry: UIRegistry { get }
    var diagnosticsStore: DiagnosticsStore { get }
    var lineCompletionEngine: LineCompletionEngine { get }

    var codebaseIndex: CodebaseIndexProtocol? { get }

    var selectionContext: CodeSelectionContext { get }
  var conversationManager: ConversationManager { get }

  var workspaceService: any WorkspaceServiceProtocol { get }

    var lastError: String? { get set }

    // UI navigation state
    var isGlobalSearchPresented: Bool { get set }
    var isQuickOpenPresented: Bool { get set }
    var isCommandPalettePresented: Bool { get set }
    var isGoToSymbolPresented: Bool { get set }

    var isNavigationLocationsPresented: Bool { get set }
    var navigationLocationsTitle: String { get set }
    var navigationLocations: [WorkspaceCodeLocation] { get set }

    var isRenameSymbolPresented: Bool { get set }
    var renameSymbolIdentifier: String { get set }

    var fileTreeExpandedRelativePaths: Set<String> { get set }
    var fileTreeSelectedRelativePath: String? { get set }
    var fileTreeRefreshToken: Int { get }

    var showHiddenFilesInFileTree: Bool { get set }

    func loadFile(from url: URL)
    func openFile()
    func newProject()
    func requestFileTreeRefresh()

    func relativePath(for url: URL) -> String?
}
