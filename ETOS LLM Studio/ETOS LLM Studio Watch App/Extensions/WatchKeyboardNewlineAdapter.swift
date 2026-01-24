// ============================================================================
// WatchKeyboardNewlineAdapter.swift
// ============================================================================
// Escapes newlines for watchOS text input and restores them on save.
// ============================================================================

import SwiftUI

extension String {
    func watchKeyboardEscapedNewlines() -> String {
        replacingOccurrences(of: "\n", with: "\\n")
    }
    
    func watchKeyboardUnescapedNewlines() -> String {
        replacingOccurrences(of: "\\n", with: "\n")
    }
}

extension Binding where Value == String {
    func watchKeyboardNewlineBinding() -> Binding<String> {
        Binding(
            get: { wrappedValue.watchKeyboardEscapedNewlines() },
            set: { wrappedValue = $0.watchKeyboardUnescapedNewlines() }
        )
    }
}
