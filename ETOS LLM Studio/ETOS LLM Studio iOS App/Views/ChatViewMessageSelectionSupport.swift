// ============================================================================
// ChatViewMessageSelectionSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 iOS 聊天气泡多选、批量导出与批量删除操作。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore
import UIKit

extension ChatView {
    func beginMessageSelection(with message: ChatMessage) {
        isMessageSelectionMode = true
        selectedMessageIDs = [message.id]
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func toggleMessageSelection(_ messageID: UUID) {
        if selectedMessageIDs.contains(messageID) {
            selectedMessageIDs.remove(messageID)
        } else {
            selectedMessageIDs.insert(messageID)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func invertMessageSelection() {
        let selectableIDs = Set(viewModel.displayMessages.map(\.message.id))
        selectedMessageIDs = BatchSelectionSupport.invertedIDs(
            selectableIDs: selectableIDs,
            selectedIDs: selectedMessageIDs
        )
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func exitMessageSelection() {
        isMessageSelectionMode = false
        selectedMessageIDs.removeAll()
        isSelectedMessagesExportPresented = false
        showSelectedMessagesDeleteConfirm = false
    }

    func exportSelectedMessages(
        format: ChatTranscriptExportFormat,
        includeReasoning: Bool,
        includeSystemPrompt: Bool
    ) {
        let selectedIDs = selectedMessageIDs
        beginTranscriptExport(
            session: viewModel.currentSession,
            messages: viewModel.allMessagesForSession,
            format: format,
            includeReasoning: includeReasoning,
            includeSystemPrompt: includeSystemPrompt,
            selectedMessageIDs: selectedIDs
        )
    }

    func deleteSelectedMessages() {
        viewModel.deleteMessages(withIDs: selectedMessageIDs)
        exitMessageSelection()
    }
}

struct SelectedMessagesExportSheet: View {
    let selectionCount: Int
    let onExport: (ChatTranscriptExportFormat, Bool, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var includeReasoning = true
    @State private var includeSystemPrompt = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(NSLocalizedString("包含思考", comment: ""), isOn: $includeReasoning)
                    Toggle(NSLocalizedString("包含系统提示词", comment: ""), isOn: $includeSystemPrompt)
                } footer: {
                    VStack(alignment: .leading) {
                        Text(
                            String(
                                format: NSLocalizedString("将导出所选的 %d 条消息。", comment: "Selected messages export footer"),
                                selectionCount
                            )
                        )
                        Text(NSLocalizedString("PNG 仅导出聊天界面可见内容，不会包含系统提示词。", comment: "Chat image export system prompt privacy note"))
                    }
                }

                Section(NSLocalizedString("导出格式", comment: "Selected messages export format section")) {
                    ForEach(ChatTranscriptExportFormat.allCases, id: \.self) { format in
                        Button {
                            dismiss()
                            onExport(format, includeReasoning, includeSystemPrompt)
                        } label: {
                            Label(format.displayName, systemImage: iconName(for: format))
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("导出所选", comment: "Selected messages export title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func iconName(for format: ChatTranscriptExportFormat) -> String {
        switch format {
        case .pdf:
            return "doc.richtext"
        case .markdown:
            return "number.square"
        case .text:
            return "doc.plaintext"
        case .png:
            return "photo"
        }
    }
}
