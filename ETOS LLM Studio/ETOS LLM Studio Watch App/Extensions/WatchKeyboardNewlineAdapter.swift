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

    func normalizedPlainQuotes() -> String {
        self
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "„", with: "\"")
            .replacingOccurrences(of: "‟", with: "\"")
            .replacingOccurrences(of: "＂", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‚", with: "'")
            .replacingOccurrences(of: "‛", with: "'")
            .replacingOccurrences(of: "＇", with: "'")
    }
}

extension Binding where Value == String {
    func watchKeyboardNewlineBinding(normalizeSmartQuotes: Bool = false) -> Binding<String> {
        Binding(
            get: { wrappedValue.watchKeyboardEscapedNewlines() },
            set: { newValue in
                let unescaped = newValue.watchKeyboardUnescapedNewlines()
                wrappedValue = normalizeSmartQuotes ? unescaped.normalizedPlainQuotes() : unescaped
            }
        )
    }
}
