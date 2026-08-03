// ============================================================================
// ChatQuickPromptEditorView.swift
// ============================================================================
// 从聊天模型选择器直接编辑当前使用的三类提示词。
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

    var body: some View {
        Form {
            Section {
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
        .onAppear(perform: syncDrafts)
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
