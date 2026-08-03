import Foundation

struct FileTreeCallbacks {
    let onOpenFile: (URL) -> Void
    let onCreateFile: (URL, String) -> Void
    let onCreateFolder: (URL, String) -> Void
    let onDeleteItem: (URL) -> Void
    let onRenameItem: (URL, String) -> Void
    let onRevealInFinder: (URL) -> Void
}
