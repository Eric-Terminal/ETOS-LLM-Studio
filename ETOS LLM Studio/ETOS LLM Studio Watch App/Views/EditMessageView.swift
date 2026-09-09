// ============================================================================
// EditMessageView.swift
// ============================================================================
// ETOS LLM Studio Watch App 消息编辑视图 (已重构)
//
// 功能特性:
// - 提供编辑消息内容和 AI 思考过程的界面
// - 保存修改后的消息
// ============================================================================

import SwiftUI
import ETOSCore

/// 用于编辑单条消息内容的视图
struct EditMessageView: View {
    
    // MARK: - 属性与回调
    
    let message: ChatMessage // 重构: 不再是绑定，只是一个不可变的初始值
    var onSave: (ChatMessage) async throws -> Void
    
    // MARK: - 状态
    
    @State private var newContent: String
    @State private var newReasoning: String
    @State private var toolCallsJSON = "[]"
    @State private var initialToolCallsJSON = "[]"
    @State private var isPrepared = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    
    // MARK: - 环境
    
    @Environment(\.dismiss) var dismiss

    // MARK: - 初始化器
    
    init(message: ChatMessage, onSave: @escaping (ChatMessage) async throws -> Void) {
        self.message = message
        self.onSave = onSave
        // 使用 @State 的初始值包装器来设置初始状态
        _newContent = State(initialValue: message.content)
        // 重构: 使用新的属性名 reasoningContent
        _newReasoning = State(initialValue: message.reasoningContent ?? "")
    }

    // MARK: - 视图主体
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(NSLocalizedString("回复内容", comment: ""))) {
                    TextField(NSLocalizedString("编辑消息", comment: ""), text: $newContent.watchKeyboardNewlineBinding(), axis: .vertical)
                        .lineLimit(5...15)
                        .listRowBackground(Color.clear)
                }
                
                // 重构: 使用 MessageRole 枚举进行判断
                if message.role == .assistant {
                    Section(header: Text(NSLocalizedString("思考过程 (可选)", comment: ""))) {
                        TextField(NSLocalizedString("编辑思考过程", comment: ""), text: $newReasoning.watchKeyboardNewlineBinding(), axis: .vertical)
                            .lineLimit(5...10)
                            .listRowBackground(Color.clear)
                    }
                }
                
                if message.role == .assistant || message.role == .tool {
                    Section {
                        NavigationLink(NSLocalizedString("工具调用 JSON", comment: "")) {
                            MessageToolCallsEditor(json: $toolCallsJSON)
                                .watchGuideEntry()
                        }
                        .disabled(!isPrepared || isSaving)
                    } footer: {
                        Text(NSLocalizedString("可以添加、修改或移除调用；正文为空也可以保存。", comment: ""))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(NSLocalizedString("保存", comment: "")) {
                    save()
                }
                .disabled(!isPrepared || isSaving)
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
            }
            .disabled(isSaving)
            .navigationTitle(NSLocalizedString("编辑消息", comment: ""))
            .guidePageContext(
                descriptor: GuidePageDescriptor(id: "message-editor", title: NSLocalizedString("编辑消息", comment: ""),
                    documents: [GuideDocumentReference(id: "message-tool-call-editing", title: NSLocalizedString("工具调用 JSON", comment: ""))]),
                snapshot: { GuidePageSnapshot(fields: [
                    "content": GuideSnapshotField(label: NSLocalizedString("回复内容", comment: ""), value: .string(""), access: .writeOnly),
                    "reasoning": GuideSnapshotField(label: NSLocalizedString("思考过程", comment: ""), value: .string(""), access: .writeOnly),
                    "tool_calls": GuideSnapshotField(label: NSLocalizedString("工具调用 JSON", comment: ""), value: .string(""), access: .writeOnly),
                    "saving": GuideSnapshotField(label: NSLocalizedString("保存", comment: ""), value: .bool(isSaving), access: .readOnly)
                ]) }
            )
            .watchGuideEntry()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .task {
            guard !isPrepared else { return }
            do {
                let calls = message.toolCalls
                let json = try await Task.detached(priority: .utility) {
                    try MessageToolCallEditingSupport.editableJSON(calls)
                }.value
                guard !Task.isCancelled else { return }
                toolCallsJSON = json
                initialToolCallsJSON = json
                isPrepared = true
            } catch { errorMessage = error.localizedDescription }
        }
        .alert(NSLocalizedString("保存失败", comment: ""), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(NSLocalizedString("确定", comment: ""), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        isSaving = true
        var updated = message
        updated.content = newContent
        updated.reasoningContent = newReasoning.isEmpty ? nil : newReasoning
        let draft = toolCallsJSON
        let hasToolChanges = draft != initialToolCallsJSON
        Task {
            defer { isSaving = false }
            do {
                if hasToolChanges {
                    let calls = try await Task.detached(priority: .userInitiated) {
                        try MessageToolCallEditingSupport.parse(draft)
                    }.value
                    updated.toolCalls = calls.isEmpty ? nil : calls
                }
                try await onSave(updated)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
