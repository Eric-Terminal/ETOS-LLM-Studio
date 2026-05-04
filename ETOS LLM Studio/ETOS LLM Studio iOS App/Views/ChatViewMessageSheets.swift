// ============================================================================
// ChatViewMessageSheets.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载聊天页的消息操作、会话信息与消息详情弹窗组件。
// ============================================================================

import SwiftUI
import Foundation
import Shared
import UIKit

struct MessageActionSheet: View {
    let payload: MessageActionSheetPayload
    let hasDisplayVersions: Bool
    let displayVersionCount: Int
    let displayCurrentVersionIndex: Int
    let canRetry: Bool
    let allMessages: [ChatMessage]
    @ObservedObject var ttsManager: TTSManager
    let onEdit: (ChatMessage) -> Void
    let onRetry: (ChatMessage) -> Void
    let onShowFullError: (String) -> Void
    let onBranch: (ChatMessage) -> Void
    let onExport: (ChatTranscriptExportFormat, Bool, ChatMessage?) -> Void
    let onSpeak: (ChatMessage) -> Void
    let onSwitchVersion: (Int, ChatMessage) -> Void
    let onDeleteVersion: (ChatMessage, Int) -> Void
    let onDelete: (ChatMessage) -> Void
    let onDownloadImages: ([String]) -> Void
    let onCopy: (ChatMessage) -> Void
    let onInfo: (ChatMessage, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var includeReasoning = true

    private var message: ChatMessage {
        payload.message
    }

    private var hasAttachments: Bool {
        message.audioFileName != nil || (message.imageFileNames?.isEmpty == false)
    }

    private var messageIndex: Int? {
        allMessages.firstIndex(where: { $0.id == message.id })
    }

    private var isSpeakingThisMessage: Bool {
        ttsManager.currentSpeakingMessageID == message.id && ttsManager.isSpeaking
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !hasAttachments {
                        Button {
                            onEdit(message)
                        } label: {
                            Label(NSLocalizedString("编辑", comment: ""), systemImage: "pencil")
                        }
                    }

                    if canRetry {
                        Button {
                            onRetry(message)
                        } label: {
                            Label(NSLocalizedString("重试", comment: ""), systemImage: "arrow.clockwise")
                        }
                    }

                    if message.role == .error, let fullContent = message.fullErrorContent {
                        Button {
                            onShowFullError(fullContent)
                        } label: {
                            Label(NSLocalizedString("查看完整响应", comment: ""), systemImage: "doc.text.magnifyingglass")
                        }
                    }

                    Button {
                        onBranch(message)
                    } label: {
                        Label(NSLocalizedString("从此处创建分支", comment: ""), systemImage: "arrow.triangle.branch")
                    }

                    if message.role == .assistant || message.role == .tool || message.role == .system {
                        Button {
                            onSpeak(message)
                        } label: {
                            Label(
                                isSpeakingThisMessage ? NSLocalizedString("停止朗读", comment: "") : NSLocalizedString("朗读消息", comment: ""),
                                systemImage: isSpeakingThisMessage ? "stop.circle" : "speaker.wave.2"
                            )
                        }
                    }
                }

                Section(NSLocalizedString("导出", comment: "")) {
                    Toggle(NSLocalizedString("包含思考", comment: ""), isOn: $includeReasoning)

                    ForEach(MessageActionExportScope.allCases) { scope in
                        Menu {
                            ForEach(ChatTranscriptExportFormat.allCases, id: \.self) { format in
                                Button {
                                    onExport(format, includeReasoning, scope == .upToMessage ? message : nil)
                                } label: {
                                    Label(format.displayName, systemImage: iconName(for: format))
                                }
                            }
                        } label: {
                            Label(
                                exportScopeTitle(scope),
                                systemImage: scope == .upToMessage ? "arrow.up.doc" : "square.and.arrow.up"
                            )
                        }
                    }
                }

                if hasDisplayVersions {
                    Section(NSLocalizedString("版本管理", comment: "")) {
                        ForEach(0..<displayVersionCount, id: \.self) { index in
                            Button {
                                onSwitchVersion(index, message)
                            } label: {
                                MessageVersionRow(
                                    index: index,
                                    isCurrent: index == displayCurrentVersionIndex
                                )
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if displayVersionCount > 1 {
                                    Button(role: .destructive) {
                                        onDeleteVersion(message, index)
                                    } label: {
                                        Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    if let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty {
                        Button {
                            onDownloadImages(imageFileNames)
                        } label: {
                            Label(NSLocalizedString("下载", comment: "Download generated image"), systemImage: "square.and.arrow.down")
                        }
                    }

                    Button {
                        onCopy(message)
                    } label: {
                        Label(NSLocalizedString("复制内容", comment: ""), systemImage: "doc.on.doc")
                    }

                    if let messageIndex {
                        Button {
                            onInfo(message, messageIndex)
                        } label: {
                            Label(NSLocalizedString("查看消息信息", comment: ""), systemImage: "info.circle")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onDelete(message)
                    } label: {
                        Label(hasDisplayVersions ? NSLocalizedString("删除所有版本", comment: "") : NSLocalizedString("删除消息", comment: ""), systemImage: "trash.fill")
                    }
                }
            }
            .navigationTitle(NSLocalizedString("消息操作", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func exportScopeTitle(_ scope: MessageActionExportScope) -> String {
        switch scope {
        case .fullSession:
            return NSLocalizedString("导出整个会话", comment: "")
        case .upToMessage:
            return NSLocalizedString("导出到此消息（含上文）", comment: "")
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
        }
    }
}

struct MessageVersionRow: View {
    let index: Int
    let isCurrent: Bool

    var body: some View {
        Label {
            HStack(spacing: 8) {
                Text(String(format: NSLocalizedString("版本 %d", comment: ""), index + 1))
                Spacer()
                if isCurrent {
                    Text(NSLocalizedString("当前", comment: ""))
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        }
    }
}

/// 会话信息弹窗，展示基础状态与唯一标识
struct SessionPickerInfoSheet: View {
    let payload: SessionPickerInfoPayload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("会话概览", comment: "")) {
                    LabeledContent(NSLocalizedString("名称", comment: "")) {
                        Text(payload.session.name)
                    }
                    LabeledContent(NSLocalizedString("状态", comment: "")) {
                        Text(payload.isCurrent ? NSLocalizedString("当前会话", comment: "") : NSLocalizedString("历史会话", comment: ""))
                            .foregroundStyle(payload.isCurrent ? Color.accentColor : Color.secondary)
                    }
                    LabeledContent(NSLocalizedString("消息数量", comment: "")) {
                        Text(String(format: NSLocalizedString("%d 条", comment: ""), payload.messageCount))
                    }
                }

                if let topic = payload.session.topicPrompt, !topic.isEmpty {
                    Section(NSLocalizedString("主题提示", comment: "")) {
                        Text(topic)
                            .etFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let enhanced = payload.session.enhancedPrompt, !enhanced.isEmpty {
                    Section(NSLocalizedString("增强提示词", comment: "")) {
                        Text(enhanced)
                            .etFont(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(NSLocalizedString("唯一标识", comment: "")) {
                    Text(payload.session.id.uuidString)
                        .etFont(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle(NSLocalizedString("会话信息", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) { dismiss() }
                }
            }
        }
    }
}

struct SessionPickerRow: View {
    let session: ChatSession
    let isCurrent: Bool
    let isRunning: Bool
    let isEditing: Bool
    @Binding var draftName: String
    let searchSummary: String?

    let onCommit: (String) -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    let onBranch: (Bool) -> Void
    let onDeleteLastMessage: () -> Void
    let onDelete: () -> Void
    let onCancelRename: () -> Void
    let onInfo: () -> Void
    let onExport: (ChatTranscriptExportFormat, Bool) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                TextField(NSLocalizedString("会话名称", comment: ""), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit {
                        commit()
                    }
                    .onAppear { focused = true }

                HStack {
                    Button(NSLocalizedString("保存", comment: "")) {
                        commit()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(NSLocalizedString("取消", comment: "")) {
                        onCancelRename()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.name)
                            .etFont(.headline)
                        if let searchSummary, !searchSummary.isEmpty {
                            Text(searchSummary)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                        } else if let topic = session.topicPrompt, !topic.isEmpty {
                            Text(topic)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if isRunning {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                    }

                    if isCurrent {
                        Image(systemName: "checkmark")
                            .etFont(.footnote.bold())
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                }
            }
        }
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label(NSLocalizedString("切换到此会话", comment: ""), systemImage: "checkmark.circle")
            }

            Button {
                onRename()
            } label: {
                Label(NSLocalizedString("重命名", comment: ""), systemImage: "pencil")
            }

            Button {
                onBranch(false)
            } label: {
                Label(NSLocalizedString("创建提示词分支", comment: ""), systemImage: "arrow.branch")
            }

            Button {
                onBranch(true)
            } label: {
                Label(NSLocalizedString("复制历史创建分支", comment: ""), systemImage: "arrow.triangle.branch")
            }

            Button {
                onDeleteLastMessage()
            } label: {
                Label(NSLocalizedString("删除最后一条消息", comment: ""), systemImage: "delete.backward")
            }

            Button {
                onInfo()
            } label: {
                Label(NSLocalizedString("查看会话信息", comment: ""), systemImage: "info.circle")
            }

            Menu {
                Menu(NSLocalizedString("包含思考", comment: "")) {
                    Button {
                        onExport(.pdf, true)
                    } label: {
                        Label("PDF", systemImage: "doc.richtext")
                    }
                    Button {
                        onExport(.markdown, true)
                    } label: {
                        Label("Markdown", systemImage: "number.square")
                    }
                    Button {
                        onExport(.text, true)
                    } label: {
                        Label("TXT", systemImage: "doc.plaintext")
                    }
                }
                Menu(NSLocalizedString("不包含思考", comment: "")) {
                    Button {
                        onExport(.pdf, false)
                    } label: {
                        Label("PDF", systemImage: "doc.richtext")
                    }
                    Button {
                        onExport(.markdown, false)
                    } label: {
                        Label("Markdown", systemImage: "number.square")
                    }
                    Button {
                        onExport(.text, false)
                    } label: {
                        Label("TXT", systemImage: "doc.plaintext")
                    }
                }
            } label: {
                Label(NSLocalizedString("导出会话", comment: ""), systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(NSLocalizedString("删除会话", comment: ""), systemImage: "trash")
            }
        }
    }

    private func commit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}
