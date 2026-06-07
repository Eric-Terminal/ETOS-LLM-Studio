// ============================================================================
// WatchThirdPartyKeyboardTextField.swift
// ============================================================================
// ETOS LLM Studio Watch App 第三方键盘适配
// ============================================================================

import SwiftUI
import ETOSCore
#if canImport(CepheusKeyboardKit)
import CepheusKeyboardKit
#endif

struct TextField<Label>: View where Label: View {
    private enum Storage {
        case text(
            prompt: String,
            text: Binding<String>,
            axis: Axis?,
            onEditingChanged: (Bool) -> Void,
            onCommit: () -> Void
        )
        case system(AnyView)
    }

    private let storage: Storage
    @ObservedObject private var appConfig = AppConfigStore.shared

    init<S>(
        _ title: S,
        text: Binding<String>,
        onEditingChanged: @escaping (Bool) -> Void = { _ in },
        onCommit: @escaping () -> Void = {}
    ) where S: StringProtocol, Label == Text {
        storage = .text(
            prompt: String(title),
            text: text,
            axis: nil,
            onEditingChanged: onEditingChanged,
            onCommit: onCommit
        )
    }

    init<S>(_ title: S, text: Binding<String>, axis: Axis) where S: StringProtocol, Label == Text {
        storage = .text(
            prompt: String(title),
            text: text,
            axis: axis,
            onEditingChanged: { _ in },
            onCommit: {}
        )
    }

    init<V, F>(_ title: String, value: Binding<V>, formatter: F) where F: Formatter, Label == Text {
        storage = .system(AnyView(SwiftUI.TextField(title, value: value, formatter: formatter)))
    }

    var body: some View {
        switch storage {
        case let .text(prompt, text, axis, onEditingChanged, onCommit):
            if appConfig.watchUseThirdPartyKeyboard {
                thirdPartyTextField(prompt: prompt, text: text, onSubmit: onCommit)
            } else if let axis {
                SwiftUI.TextField(prompt, text: text, axis: axis)
            } else {
                SwiftUI.TextField(prompt, text: text, onEditingChanged: onEditingChanged, onCommit: onCommit)
            }
        case let .system(view):
            view
        }
    }

    @ViewBuilder
    private func thirdPartyTextField(prompt: String, text: Binding<String>, onSubmit: @escaping () -> Void) -> some View {
        #if canImport(CepheusKeyboardKit)
        CepheusKeyboard(
            input: text,
            prompt: LocalizedStringResource(stringLiteral: prompt),
            CepheusIsEnabled: true,
            defaultLanguage: "zh-hans-pinyin",
            onSubmit: onSubmit
        )
        #else
        SwiftUI.TextField(prompt, text: text)
        #endif
    }
}
