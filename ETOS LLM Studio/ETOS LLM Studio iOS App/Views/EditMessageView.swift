// ============================================================================
// EditMessageView.swift
// ============================================================================
// EditMessageView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import ETOSCore

struct EditMessageView: View {
    let message: ChatMessage
    let onSave: (ChatMessage) async throws -> Void
    @State private var content: String
    @State private var reasoning: String
    @State private var toolCallsJSON = "[]"
    @State private var initialToolCallsJSON = "[]"
    @State private var isPrepared = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    
    init(message: ChatMessage, onSave: @escaping (ChatMessage) async throws -> Void) {
        self.message = message
        self.onSave = onSave
        _content = State(initialValue: message.content)
        _reasoning = State(initialValue: message.reasoningContent ?? "")
    }
    
    var body: some View {
        Form {
            Section(NSLocalizedString("消息内容", comment: "")) {
                TextEditor(text: $content)
                    .frame(minHeight: 160)
            }
            
            if message.role == .assistant {
                Section(NSLocalizedString("思考过程", comment: "")) {
                    TextEditor(text: $reasoning)
                        .frame(minHeight: 120)
                }
            }
            if message.role == .assistant || message.role == .tool {
                Section {
                    NavigationLink(NSLocalizedString("工具调用 JSON", comment: "")) {
                        MessageToolCallsEditor(json: $toolCallsJSON)
                    }
                    .disabled(!isPrepared || isSaving)
                } footer: {
                    Text(NSLocalizedString("可以添加、修改或移除调用；正文为空也可以保存。", comment: ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .navigationTitle(NSLocalizedString("编辑消息", comment: ""))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "")) { dismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "")) {
                    save()
                }
                .disabled(!isPrepared || isSaving)
            }
        }
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
        .guidePageContext(
            descriptor: GuidePageDescriptor(id: "message-editor", title: NSLocalizedString("编辑消息", comment: ""),
                documents: [GuideDocumentReference(id: "message-tool-call-editing", title: NSLocalizedString("工具调用 JSON", comment: ""))]),
            snapshot: { GuidePageSnapshot(fields: [
                "content": GuideSnapshotField(label: NSLocalizedString("消息内容", comment: ""), value: .string(""), access: .writeOnly),
                "reasoning": GuideSnapshotField(label: NSLocalizedString("思考过程", comment: ""), value: .string(""), access: .writeOnly),
                "tool_calls": GuideSnapshotField(label: NSLocalizedString("工具调用 JSON", comment: ""), value: .string(""), access: .writeOnly),
                "saving": GuideSnapshotField(label: NSLocalizedString("保存", comment: ""), value: .bool(isSaving), access: .readOnly)
            ]) }
        )
        .alert(NSLocalizedString("保存失败", comment: ""), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(NSLocalizedString("确定", comment: ""), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        isSaving = true
        var updated = message
        updated.content = content
        updated.reasoningContent = reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : reasoning
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
