// ============================================================================
// WatchQuickPromptEditorView.swift
// ============================================================================
// 从模型选择页切换已保存的全局提示词，并编辑当前使用的三类提示词。
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

    private var selectedSystemPromptTitle: String {
        guard let entry = selectedSystemPrompt else {
            return NSLocalizedString("未选择", value: "Not Selected", comment: "未选择全局提示词")
        }
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? NSLocalizedString("未命名提示词", value: "Untitled Prompt", comment: "未命名全局提示词") : title
    }

    var body: some View {
        List {
            PromptMacroHelpSection {
                PromptMacroHelpView().watchGuideEntry()
            }

            Section(NSLocalizedString("系统提示词", comment: "模型选择器快速提示词编辑器分组")) {
                NavigationLink {
                    GlobalSystemPromptPickerView(
                        entries: viewModel.globalSystemPromptEntries,
                        selectedEntryID: viewModel.selectedGlobalSystemPromptEntryID,
                        addGlobalSystemPromptEntry: viewModel.addGlobalSystemPromptEntry,
                        duplicateGlobalSystemPromptEntry: viewModel.duplicateGlobalSystemPromptEntry,
                        selectGlobalSystemPromptEntry: viewModel.selectGlobalSystemPromptEntry,
                        updateGlobalSystemPromptEntry: viewModel.updateGlobalSystemPromptEntry,
                        deleteGlobalSystemPromptEntry: viewModel.deleteGlobalSystemPromptEntry
                    )
                } label: {
                    MarqueeTitleSubtitleLabel(
                        title: NSLocalizedString("提示词列表", value: "Prompt List", comment: "切换已保存的全局提示词"),
                        subtitle: selectedSystemPromptTitle
                    )
                }

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
            .readOnly("selected_global_prompt_id", label: NSLocalizedString("当前全局提示词 ID", value: "Current Global Prompt ID", comment: "快捷提示词向导字段"), value: { .string(viewModel.selectedGlobalSystemPromptEntryID?.uuidString ?? "") }),
            .readOnly("selected_global_prompt_title", label: NSLocalizedString("当前提示词", value: "Current Prompt", comment: "快捷提示词向导字段"), value: { .string(selectedSystemPromptTitle) }),
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
