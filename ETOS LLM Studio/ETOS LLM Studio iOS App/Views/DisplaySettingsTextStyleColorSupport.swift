// ============================================================================
// DisplaySettingsTextStyleColorSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 iOS 聊天文字语义样式的颜色设置视图。
// ============================================================================

import SwiftUI
import ETOSCore

struct ChatTextStyleColorSettingsView: View {
    let title: String
    @Binding var bodyColor: ChatAppearanceColorSlot
    @Binding var styleColors: ChatAppearanceTextStyleColors
    let fallback: Color

    var body: some View {
        Form {
            ForEach(FontSemanticRole.allCases) { role in
                textStyleSection(role)
            }

            customRulesSection
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var customRulesSection: some View {
        Section {
            ForEach(styleColors.customRules) { rule in
                NavigationLink {
                    ChatTextColorRuleEditorView(
                        rule: customRuleBinding(id: rule.id),
                        fallback: fallback
                    )
                } label: {
                    ChatTextColorRuleRow(rule: rule, fallback: fallback)
                }
            }
            .onDelete(perform: deleteCustomRules)
            .onMove(perform: moveCustomRules)

            Button {
                styleColors.customRules.append(
                    ChatAppearanceTextColorRule(colorHex: bodyColor.hex)
                )
            } label: {
                Label(
                    NSLocalizedString("添加着色规则", comment: ""),
                    systemImage: "plus"
                )
            }
        } header: {
            Text(NSLocalizedString("指定内容", comment: ""))
        } footer: {
            Text(NSLocalizedString("规则按从上到下的顺序匹配；靠前规则优先。代码与公式会保留各自的专用颜色。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func textStyleSection(_ role: FontSemanticRole) -> some View {
        let slot = slotBinding(for: role)
        Section {
            Toggle(NSLocalizedString("自定义颜色", comment: ""), isOn: enabledBinding(slot))

            if slot.wrappedValue.isEnabled {
                ColorPicker(
                    NSLocalizedString("颜色", comment: ""),
                    selection: colorBinding(slot),
                    supportsOpacity: false
                )
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

    private func colorBinding(_ slot: Binding<ChatAppearanceColorSlot>) -> Binding<Color> {
        Binding(
            get: { ChatAppearanceColorCodec.color(from: slot.wrappedValue.hex, fallback: fallback) },
            set: { color in
                guard let hex = ChatAppearanceColorCodec.hexRGBA(from: color) else { return }
                var updated = slot.wrappedValue
                updated.hex = hex
                slot.wrappedValue = updated
            }
        )
    }

    private func customRuleBinding(id: String) -> Binding<ChatAppearanceTextColorRule> {
        Binding(
            get: {
                styleColors.customRules.first { $0.id == id }
                    ?? ChatAppearanceTextColorRule(id: id, colorHex: bodyColor.hex)
            },
            set: { updatedRule in
                guard let index = styleColors.customRules.firstIndex(where: { $0.id == id }) else {
                    return
                }
                styleColors.customRules[index] = updatedRule
            }
        )
    }

    private func deleteCustomRules(at offsets: IndexSet) {
        styleColors.customRules.remove(atOffsets: offsets)
    }

    private func moveCustomRules(from source: IndexSet, to destination: Int) {
        styleColors.customRules.move(fromOffsets: source, toOffset: destination)
    }
}
