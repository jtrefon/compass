import Foundation

extension TypedCommand where Args == ExplorerPathArgs {
    public static let explorerOpenSelection = TypedCommand(.explorerOpenSelection)
    public static let explorerDeleteSelection = TypedCommand(.explorerDeleteSelection)
    public static let explorerRevealInFinder = TypedCommand(.explorerRevealInFinder)
}
