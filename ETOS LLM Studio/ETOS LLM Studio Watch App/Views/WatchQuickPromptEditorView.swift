// ============================================================================
// WatchQuickPromptEditorView.swift
// ============================================================================
// 从模型选择页直接编辑当前使用的三类提示词。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct WatchQuickPromptEditorView: View {
    @ObservedObject var viewModel: ChatViewModel

    private var selectedSystemPrompt: GlobalSystemPromptEntry? {
        guard let selectedID = viewModel.selectedGlobalSystemPromptEntryID else { return nil }
        return viewModel.globalSystemPromptEntries.first(where: { $0.id == selectedID })
    }

    var body: some View {
        List {
            PromptMacroHelpSection {
                PromptMacroHelpView().watchGuideEntry()
            }

            Section(NSLocalizedString("系统提示词", comment: "模型选择器快速提示词编辑器分组")) {
                TextField(
                    NSLocalizedString("自定义全局系统提示词", comment: ""),
                    text: systemPromptBinding.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                .lineLimit(3...8)
                .disabled(selectedSystemPrompt == nil)
            }

            Section {
                TextField(
                    NSLocalizedString("自定义话题提示词", comment: ""),
                    text: topicPromptBinding.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                .lineLimit(3...8)
                .disabled(viewModel.currentSession == nil)
            } header: {
                Text(NSLocalizedString("当前话题提示词", comment: ""))
            } footer: {
                Text(NSLocalizedString("仅对当前对话生效。", comment: ""))
            }

            Section(NSLocalizedString("增强提示词", comment: "")) {
                TextField(
                    NSLocalizedString("自定义增强提示词", comment: ""),
                    text: enhancedPromptBinding.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                .lineLimit(3...8)
                .disabled(viewModel.currentSession == nil)
            }
        }
        .navigationTitle(NSLocalizedString("提示词", comment: "快速提示词编辑器标题"))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "chat-quick-prompts-\(viewModel.currentSession?.id.uuidString ?? "none")-\(viewModel.selectedGlobalSystemPromptEntryID?.uuidString ?? "none")"),
            title: NSLocalizedString("提示词", comment: "快速提示词编辑器标题"),
            documents: [GuideDocumentReference(id: "settings-core", title: "Core Settings")],
            settings: guideSettings
        )
        .watchGuideEntry()
    }

    private var guideSettings: [GuidePageSetting] {
        var settings: [GuidePageSetting] = [
            .readOnly("save_required", label: NSLocalizedString("修改后需要保存", comment: "向导保存说明"), value: { .bool(false) })
        ]
        if selectedSystemPrompt != nil {
            settings.append(.string("system_prompt", label: NSLocalizedString("系统提示词", comment: ""), get: { systemPromptBinding.wrappedValue }, set: { systemPromptBinding.wrappedValue = $0 }))
        }
        if viewModel.currentSession != nil {
            settings.append(.string("topic_prompt", label: NSLocalizedString("当前话题提示词", comment: ""), get: { topicPromptBinding.wrappedValue }, set: { topicPromptBinding.wrappedValue = $0 }))
            settings.append(.string("enhanced_prompt", label: NSLocalizedString("增强提示词", comment: ""), get: { enhancedPromptBinding.wrappedValue }, set: { enhancedPromptBinding.wrappedValue = $0 }))
        }
        return settings
    }

    private var systemPromptBinding: Binding<String> {
        Binding(
            get: { selectedSystemPrompt?.content ?? "" },
            set: viewModel.updateSelectedGlobalSystemPromptContent
        )
    }

    private var topicPromptBinding: Binding<String> {
        Binding(
            get: { viewModel.currentSession?.topicPrompt ?? "" },
            set: { prompt in
                updateCurrentSessionPrompt { session in
                    session.topicPrompt = prompt
                }
            }
        )
    }

    private var enhancedPromptBinding: Binding<String> {
        Binding(
            get: { viewModel.currentSession?.enhancedPrompt ?? "" },
            set: { prompt in
                updateCurrentSessionPrompt { session in
                    session.enhancedPrompt = prompt
                }
            }
        )
    }

    private func updateCurrentSessionPrompt(
        _ update: (inout ChatSession) -> Void
    ) {
        guard var session = viewModel.currentSession else { return }
        update(&session)
        viewModel.currentSession = session
        ChatService.shared.updateSession(session)
    }
}
