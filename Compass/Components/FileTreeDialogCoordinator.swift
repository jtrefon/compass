//
//  FileTreeDialogCoordinator.swift
//  Compass
//
//  Created by AI Assistant on 11/01/2026.
//

import Foundation
import AppKit

/// Handles dialog interactions for the file tree
@MainActor
final class FileTreeDialogCoordinator {

    private func promptForString(
        title: String,
        informativeText: String,
        buttonTitle: String,
        initialValue: String = ""
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informativeText
        alert.alertStyle = .informational
        alert.addButton(withTitle: buttonTitle)
        alert.addButton(withTitle: NSLocalizedString("common.cancel", comment: ""))

        let textField = NSTextField(string: initialValue)
        textField.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Prompts user for renaming an item
    func promptForRename(initialName: String) -> String? {
        promptForString(
            title: NSLocalizedString("file_tree.rename.title", comment: ""),
            informativeText: NSLocalizedString("file_tree.rename.info", comment: ""),
            buttonTitle: NSLocalizedString("file_tree.rename.button", comment: ""),
            initialValue: initialName
        )
    }

    /// Prompts user for creating a new item
    func promptForNewItem(title: String, informativeText: String) -> String? {
        promptForString(
            title: title,
            informativeText: informativeText,
            buttonTitle: NSLocalizedString("file_tree.create.button", comment: "")
        )
    }
}
