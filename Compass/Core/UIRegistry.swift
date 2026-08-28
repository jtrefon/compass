//
//  UIRegistry.swift
//  Compass
//
//  Created by Jack Trefon on 21/12/2025.
//

import SwiftUI
import Combine

/// A type-erased view provider to allow heterogeneous collections.
public struct PluginView: Identifiable {
    public let id = UUID()
    public let makeView: () -> AnyView
    public let name: String
    public let iconName: String?

    public var displayName: String {
        name.replacingOccurrences(of: "Internal.", with: "")
    }

    public init<V: View>(name: String, iconName: String? = nil, makeView: @escaping () -> V) {
        self.name = name
        self.iconName = iconName
        self.makeView = { AnyView(makeView()) }
    }
}

/// The centralized registry for UI components.
/// Plugins register their views here, and the ContentView renders them dynamically.
@MainActor
public final class UIRegistry: ObservableObject {
    @Published private var extensions: [ExtensionPoint: [PluginView]] = [:]

    public init() {}

    /// Registers a view for a specific extension point.
    /// - Parameters:
    ///   - point: The location to inject the view.
    ///   - name: A display name for the extension (e.g. for tabs).
    ///   - icon: An optional system image name.
    ///   - view: The SwiftUI view to render.
    public func register<V: View>(point: ExtensionPoint, name: String, icon: String? = nil, view: V) {
        register(point: point, name: name, icon: icon, makeView: { view })
    }

    /// Registers a lazily-created view for a specific extension point.
    /// - Parameters:
    ///   - point: The location to inject the view.
    ///   - name: A display name for the extension (e.g. for tabs).
    ///   - icon: An optional system image name.
    ///   - makeView: A view factory used to create the view at render time.
    public func register<V: View>(
        point: ExtensionPoint,
        name: String,
        icon: String? = nil,
        makeView: @escaping () -> V
    ) {
        if extensions[point] == nil {
            extensions[point] = []
        }
        let pluginView = PluginView(name: name, iconName: icon, makeView: makeView)
        extensions[point]?.append(pluginView)

    }

    /// Retrieves all registered views for an extension point.
    public func views(for point: ExtensionPoint) -> [PluginView] {
        return extensions[point] ?? []
    }
}
