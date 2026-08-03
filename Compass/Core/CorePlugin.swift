//
//  CorePlugin.swift
//  Compass
//
//  Created by Jack Trefon on 21/12/2025.
//

import SwiftUI
import AppKit

/// The "Default Plugin" that registers the core UI components of the IDE.
/// In the future, these components could be fully separated into their own modules.
@MainActor
final class CorePlugin {
    static func initialize<Context: IDEContext & ObservableObject>(registry: UIRegistry, context: Context) {
        CoreUIRegistrar(registry: registry, context: context).registerAll()
        CoreCommandRegistrar(commandRegistry: context.commandRegistry, context: context).registerAll()
    }
}
