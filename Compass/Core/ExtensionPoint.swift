//
//  ExtensionPoint.swift
//  Compass
//
//  Created by Jack Trefon on 21/12/2025.
//

import Foundation

/// Defines valid locations where plugins can inject UI elements.
public enum ExtensionPoint: String, CaseIterable, Hashable {
    /// The left sidebar (e.g., File Explorer, Search)
    case sidebarLeft = "ide.sidebar.left"

    /// The right panel (e.g., AI Chat, Inspector)
    case panelRight = "ide.panel.right"

    /// The bottom panel (e.g., Terminal, Debug Output)
    case panelBottom = "ide.panel.bottom"

    /// The main editor area (typically replaced, not appended to)
    case editor = "ide.editor"

    /// The status bar
    case statusbar = "ide.statusbar"
}
