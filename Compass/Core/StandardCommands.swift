//
//  StandardCommands.swift
//  Compass
//
//  Created by Jack Trefon on 21/12/2025.
//

import Foundation

/// Defines the standard set of commands that the IDE supports.
/// Plugins can intercept these or the UI can trigger them.
extension CommandID {
    // MARK: - File Operations
    public static let fileNew: CommandID = "file.new"
    public static let projectNew: CommandID = "project.new"
    public static let fileOpen: CommandID = "file.open"
    public static let fileOpenFolder: CommandID = "file.openFolder"
    public static let fileSave: CommandID = "file.save"
    public static let fileSaveAs: CommandID = "file.saveAs"

    // MARK: - File Explorer
    public static let explorerOpenSelection: CommandID = "explorer.openSelection"
    public static let explorerDeleteSelection: CommandID = "explorer.deleteSelection"
    public static let explorerRenameSelection: CommandID = "explorer.renameSelection"
    public static let explorerRevealInFinder: CommandID = "explorer.revealInFinder"

    // MARK: - Editor Operations
    public static let editorFormat: CommandID = "editor.format"

    public static let editorToggleFold: CommandID = "editor.toggleFold"
    public static let editorUnfoldAll: CommandID = "editor.unfoldAll"

    public static let editorAddNextOccurrence: CommandID = "editor.addNextOccurrence"
    public static let editorAddCursorAbove: CommandID = "editor.addCursorAbove"
    public static let editorAddCursorBelow: CommandID = "editor.addCursorBelow"

    public static let editorTriggerInlineCompletion: CommandID = "editor.triggerInlineCompletion"
    public static let editorAIInlineAssist: CommandID = "editor.aiInlineAssist"
    public static let editorAIInlineQuestion: CommandID = "editor.aiInlineQuestion"

    public static let viewToggleMinimap: CommandID = "view.toggleMinimap"
    public static let viewToggleMarkdownPreview: CommandID = "view.toggleMarkdownPreview"

    public static let editorGoToDefinition: CommandID = "editor.goToDefinition"
    public static let editorFindReferences: CommandID = "editor.findReferences"
    public static let editorRenameSymbol: CommandID = "editor.renameSymbol"

    public static let editorTabsCloseActive: CommandID = "editor.tabs.closeActive"
    public static let editorTabsCloseAll: CommandID = "editor.tabs.closeAll"
    public static let editorTabsNext: CommandID = "editor.tabs.next"
    public static let editorTabsPrevious: CommandID = "editor.tabs.previous"

    public static let editorSplitRight: CommandID = "editor.splitRight"
    public static let editorSplitDown: CommandID = "editor.splitDown"
    public static let editorFocusNextGroup: CommandID = "editor.focusNextGroup"

    public static let editorFind: CommandID = "editor.find"
    public static let editorReplace: CommandID = "editor.replace"

    // MARK: - Workbench / Search
    public static let searchFindInWorkspace: CommandID = "search.findInWorkspace"
    public static let workbenchQuickOpen: CommandID = "workbench.quickOpen"

    // MARK: - Problems / Diagnostics
    public static let viewToggleProblems: CommandID = "view.toggleProblems"
    public static let problemsNext: CommandID = "problems.next"
    public static let problemsPrevious: CommandID = "problems.previous"

    public static let workbenchCommandPalette: CommandID = "workbench.commandPalette"
    public static let workbenchGoToSymbol: CommandID = "workbench.goToSymbol"
}
