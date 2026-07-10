// ============================================================================
// DisplaySettingsTextStyleColorSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 watchOS 聊天文字语义样式的颜色设置视图。
// ============================================================================

import SwiftUI
import ETOSCore

struct WatchTextStyleColorSettingsView: View {
    let title: String
    @Binding var bodyColor: ChatAppearanceColorSlot
    @Binding var styleColors: ChatAppearanceTextStyleColors
    let fallback: Color

    var body: some View {
        Form {
            ForEach(FontSemanticRole.allCases) { role in
                textStyleSection(role)
            }
        }
        .navigationTitle(title)
    }

    @ViewBuilder
    private func textStyleSection(_ role: FontSemanticRole) -> some View {
        let slot = slotBinding(for: role)
        Section {
            Toggle(NSLocalizedString("自定义颜色", comment: ""), isOn: enabledBinding(slot))

            if slot.wrappedValue.isEnabled {
                NavigationLink {
                    WatchColorEditorView(
                        title: role.title,
                        hexValue: hexBinding(slot),
                        fallback: fallback,
                        description: colorDescription(for: role)
                    )
                } label: {
                    HStack {
                        Text(String(format: NSLocalizedString("设置%@", comment: ""), role.title))
                        Spacer(minLength: 8)
                        Circle()
                            .fill(ChatAppearanceColorCodec.color(from: slot.wrappedValue.hex, fallback: fallback))
                            .overlay(
                                Circle()
                                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                            )
                            .frame(width: 14, height: 14)
                    }
                }
            }
        } header: {
            Text(role.title)
        } footer: {
            if role == .code {
                Text(NSLocalizedString("启用自定义代码颜色后，代码会统一使用该颜色，并停止自动语法着色。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func slotBinding(for role: FontSemanticRole) -> Binding<ChatAppearanceColorSlot> {
        switch role {
        case .body:
            return $bodyColor
        case .emphasis:
            return styleSlotBinding(\.emphasis)
        case .strong:
            return styleSlotBinding(\.strong)
        case .code:
            return styleSlotBinding(\.code)
        }
    }

    private func styleSlotBinding(
        _ keyPath: WritableKeyPath<ChatAppearanceTextStyleColors, ChatAppearanceColorSlot>
    ) -> Binding<ChatAppearanceColorSlot> {
        Binding(
            get: { styleColors[keyPath: keyPath] },
            set: { styleColors[keyPath: keyPath] = $0 }
        )
    }

    private func enabledBinding(_ slot: Binding<ChatAppearanceColorSlot>) -> Binding<Bool> {
        Binding(
            get: { slot.wrappedValue.isEnabled },
            set: { isEnabled in
                var updated = slot.wrappedValue
                updated.isEnabled = isEnabled
                slot.wrappedValue = updated
            }
        )
    }

    private func hexBinding(_ slot: Binding<ChatAppearanceColorSlot>) -> Binding<String> {
        Binding(
            get: { slot.wrappedValue.hex },
            set: { hex in
                var updated = slot.wrappedValue
                updated.hex = hex
                slot.wrappedValue = updated
            }
        )
    }

    private func colorDescription(for role: FontSemanticRole) -> String {
        if role == .code {
            return NSLocalizedString("启用自定义代码颜色后，代码会统一使用该颜色，并停止自动语法着色。", comment: "")
        }
        return NSLocalizedString("设置该文字样式在聊天内容中的颜色。", comment: "")
    }
}
