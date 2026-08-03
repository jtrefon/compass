import SwiftUI

struct ModernFileTreeCoordinatorConfiguration {
    let expandedRelativePaths: Binding<Set<String>>
    let selectedRelativePath: Binding<String?>
    let onOpenFile: (URL) -> Void
    let onCreateFile: (URL, String) -> Void
    let onCreateFolder: (URL, String) -> Void
    let onDeleteItem: (URL) -> Void
    let onRenameItem: (URL, String) -> Void
    let onRevealInFinder: (URL) -> Void
}
