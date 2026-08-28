//
//  FileTreeAppearanceCoordinator.swift
//  Compass
//
//  Created by AI Assistant on 11/01/2026.
//

import AppKit
import Foundation

/// Handles appearance and styling for the file tree
@MainActor
final class FileTreeAppearanceCoordinator {
    private weak var outlineView: NSOutlineView?
    private var fontSize: Double = 13
    private var fontFamily: String = AppConstants.Editor.defaultFontFamily

    init(outlineView: NSOutlineView) {
        self.outlineView = outlineView
    }

    /// Updates the appearance of visible rows
    func applyAppearanceToVisibleRows() {
        guard let outlineView = outlineView else { return }

        let rowHeight = fontSize + 6
        outlineView.rowHeight = rowHeight

        // Only iterate over visible rows to avoid CPU spikes in large projects
        let visibleRows = outlineView.rows(in: outlineView.visibleRect)
        guard visibleRows.location != NSNotFound else { return }

        for row in visibleRows.location..<NSMaxRange(visibleRows) {
            if let cellView = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? NSTableCellView
            {
                if let textField = cellView.textField {
                    textField.font = NSFont(name: fontFamily, size: fontSize)
                    textField.textColor = NSColor.controlTextColor
                }
            }
        }
    }

    /// Updates the font settings
    func updateFont(fontSize: Double, fontFamily: String) {
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        applyAppearanceToVisibleRows()
    }
}
