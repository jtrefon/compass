//
//  CodeSelectionContext.swift
//  Compass
//
//  Created by Jack Trefon on 21/12/2025.
//

import SwiftUI
import Combine

/// Manages the context of the currently selected code in the editor.
/// This allows other components (like AI Chat) to be aware of user selection.
public class CodeSelectionContext: ObservableObject {
    @Published public var selectedText: String = ""
    @Published public var selectedRange: NSRange?

    public init() {}
}
