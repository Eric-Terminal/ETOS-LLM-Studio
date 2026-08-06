// ============================================================================
// EditSessionNameView.swift
// ============================================================================
// ETOS LLM Studio Watch App 会话名称编辑视图
//
// 功能特性:
// - 提供编辑会话（话题）名称的界面
// - 保存修改后的名称
// ============================================================================

import SwiftUI
import ETOSCore

/// 用于编辑会话名称的视图
struct EditSessionNameView: View {
    
    // MARK: - 绑定与属性
    
    @Binding var session: ChatSession
    var onSave: (ChatSession) -> Void
    
    // MARK: - 状态
    
    @State private var newName: String
    @State private var systemPrompt: String
    @State private var topicPrompt: String
    @State private var enhancedPrompt: String
    @State private var preferredModelIdentifier: String
    
    // MARK: - 环境
    
    @Environment(\.dismiss) var dismiss

    // MARK: - 初始化器
    
    init(session: Binding<ChatSession>, onSave: @escaping (ChatSession) -> Void) {
        _session = session
        self.onSave = onSave
        _newName = State(initialValue: session.wrappedValue.name)
        _systemPrompt = State(initialValue: session.wrappedValue.systemPrompt ?? "")
        _topicPrompt = State(initialValue: session.wrappedValue.topicPrompt ?? "")
        _enhancedPrompt = State(initialValue: session.wrappedValue.enhancedPrompt ?? "")
        _preferredModelIdentifier = State(initialValue: session.wrappedValue.preferredModelIdentifier ?? "")
    }

    // MARK: - 视图主体
    
    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("会话名称", comment: "")) {
                    TextField(NSLocalizedString("输入新名称", comment: ""), text: $newName.watchKeyboardNewlineBinding())
                }
                Section(NSLocalizedString("会话提示词", comment: "Conversation-specific prompts")) {
                    TextField(NSLocalizedString("会话系统提示词", comment: "Conversation system prompt"), text: $systemPrompt.watchKeyboardNewlineBinding())
                    TextField(NSLocalizedString("主题提示", comment: ""), text: $topicPrompt.watchKeyboardNewlineBinding())
                    TextField(NSLocalizedString("增强提示词", comment: ""), text: $enhancedPrompt.watchKeyboardNewlineBinding())
                }
                Section(NSLocalizedString("首选模型", comment: "Preferred conversation model")) {
                    Picker(NSLocalizedString("首选模型", comment: "Preferred conversation model"), selection: $preferredModelIdentifier) {
                        Text(NSLocalizedString("跟随全局模型", comment: "Follow global model")).tag("")
                        ForEach(ChatService.shared.activatedConversationModels, id: \.id) { model in
                            Text(model.model.displayName).tag(model.id)
                        }
                    }
                }
                Button(NSLocalizedString("保存", comment: "")) {
                    session.name = newName
                    session.systemPrompt = normalized(systemPrompt)
                    session.topicPrompt = normalized(topicPrompt)
                    session.enhancedPrompt = normalized(enhancedPrompt)
                    session.preferredModelIdentifier = preferredModelIdentifier.isEmpty ? nil : preferredModelIdentifier
                    onSave(session)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle(NSLocalizedString("编辑话题", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }
}
