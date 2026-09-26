// ============================================================================
// ChatQuickPromptEditorView.swift
// ============================================================================
// 从聊天模型选择器切换已保存的全局提示词，并编辑当前使用的三类提示词。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

@MainActor
struct ChatQuickPromptEditorView: View {
    @ObservedObject var viewModel: ChatViewModel

    @State private var systemPromptDraft = ""
    @State private var topicPromptDraft = ""
    @State private var enhancedPromptDraft = ""

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
        Form {
            PromptMacroHelpSection()

            Section {
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

                FullscreenMultilineTextInput(
                    identity: selectedSystemPrompt?.id.uuidString ?? "system-prompt-none",
                    placeholder: NSLocalizedString("自定义全局系统提示词", comment: ""),
                    fullScreenTitle: NSLocalizedString("编辑提示词", comment: ""),
                    text: $systemPromptDraft,
                    lineLimit: 3...8,
                    isEnabled: selectedSystemPrompt != nil,
                    onDebouncedSave: viewModel.updateSelectedGlobalSystemPromptContent
                )
            } header: {
                Text(NSLocalizedString("系统提示词", comment: "模型选择器快速提示词编辑器分组"))
            }

            Section {
                FullscreenMultilineTextInput(
                    identity: promptIdentity(suffix: "topic"),
                    placeholder: NSLocalizedString("自定义话题提示词", comment: ""),
                    fullScreenTitle: NSLocalizedString("编辑提示词", comment: ""),
                    text: $topicPromptDraft,
                    lineLimit: 2...6,
                    isEnabled: viewModel.currentSession != nil,
                    onDebouncedSave: updateTopicPrompt
                )
            } header: {
                Text(NSLocalizedString("当前话题提示词", comment: ""))
            } footer: {
                Text(NSLocalizedString("仅对当前对话生效。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                FullscreenMultilineTextInput(
                    identity: promptIdentity(suffix: "enhanced"),
                    placeholder: NSLocalizedString("自定义增强提示词", comment: ""),
                    fullScreenTitle: NSLocalizedString("编辑提示词", comment: ""),
                    text: $enhancedPromptDraft,
                    lineLimit: 2...6,
                    isEnabled: viewModel.currentSession != nil,
                    onDebouncedSave: updateEnhancedPrompt
                )
            } header: {
                Text(NSLocalizedString("增强提示词", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("提示词", comment: "快速提示词编辑器标题"))
        .navigationBarTitleDisplayMode(.inline)
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "chat-quick-prompts-\(viewModel.currentSession?.id.uuidString ?? "none")-\(viewModel.selectedGlobalSystemPromptEntryID?.uuidString ?? "none")"),
            title: NSLocalizedString("提示词", comment: "快速提示词编辑器标题"),
            documents: [GuideDocumentReference(id: "settings-core", title: "Core Settings")],
            settings: guideSettings
        )
        .onAppear(perform: syncDrafts)
        .onChange(of: viewModel.selectedGlobalSystemPromptEntryID) { _, _ in
            systemPromptDraft = selectedSystemPrompt?.content ?? ""
        }
        .onChange(of: selectedSystemPrompt?.content ?? "") { _, content in
            systemPromptDraft = content
        }
        .onChange(of: viewModel.currentSession?.id) { _, _ in
            syncSessionDrafts()
        }
        .onChange(of: viewModel.currentSession?.topicPrompt ?? "") { _, prompt in
            topicPromptDraft = prompt
        }
        .onChange(of: viewModel.currentSession?.enhancedPrompt ?? "") { _, prompt in
            enhancedPromptDraft = prompt
        }
    }

    private var guideSettings: [GuidePageSetting] {
        var settings: [GuidePageSetting] = [
            .readOnly("selected_global_prompt_id", label: NSLocalizedString("当前全局提示词 ID", value: "Current Global Prompt ID", comment: "快捷提示词向导字段"), value: { .string(viewModel.selectedGlobalSystemPromptEntryID?.uuidString ?? "") }),
            .readOnly("selected_global_prompt_title", label: NSLocalizedString("当前提示词", value: "Current Prompt", comment: "快捷提示词向导字段"), value: { .string(selectedSystemPromptTitle) }),
            .readOnly("save_required", label: NSLocalizedString("修改后需要保存", comment: "向导保存说明"), value: { .bool(false) })
        ]
        if selectedSystemPrompt != nil {
            settings.append(.string("system_prompt", label: NSLocalizedString("系统提示词", comment: ""), get: { systemPromptDraft }, set: {
                systemPromptDraft = $0
                viewModel.updateSelectedGlobalSystemPromptContent($0)
            }))
        }
        if viewModel.currentSession != nil {
            settings.append(.string("topic_prompt", label: NSLocalizedString("当前话题提示词", comment: ""), get: { topicPromptDraft }, set: {
                topicPromptDraft = $0
                updateTopicPrompt($0)
            }))
            settings.append(.string("enhanced_prompt", label: NSLocalizedString("增强提示词", comment: ""), get: { enhancedPromptDraft }, set: {
                enhancedPromptDraft = $0
                updateEnhancedPrompt($0)
            }))
        }
        return settings
    }

    private func promptIdentity(suffix: String) -> String {
        "\(viewModel.currentSession?.id.uuidString ?? "none")-\(suffix)"
    }

    private func syncDrafts() {
        systemPromptDraft = selectedSystemPrompt?.content ?? ""
        syncSessionDrafts()
    }

    private func syncSessionDrafts() {
        topicPromptDraft = viewModel.currentSession?.topicPrompt ?? ""
        enhancedPromptDraft = viewModel.currentSession?.enhancedPrompt ?? ""
    }

    private func updateTopicPrompt(_ prompt: String) {
        updateCurrentSessionPrompt { session in
            session.topicPrompt = prompt
        }
    }

    private func updateEnhancedPrompt(_ prompt: String) {
        updateCurrentSessionPrompt { session in
            session.enhancedPrompt = prompt
        }
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
