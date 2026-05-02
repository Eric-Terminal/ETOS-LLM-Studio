// ============================================================================
// SessionListView.swift
// ============================================================================
// 会话管理界面 (iOS)
// - 文件夹与会话合并展示，保持文件管理式浏览
// - 支持新建/重命名/删除文件夹
// - 支持批量选择会话/文件夹并批量移动、批量删除
// ============================================================================

import Foundation
import Shared
import SwiftUI

struct SessionListView: View {
    let createConversationAction: (() -> Void)?

    init(createConversationAction: (() -> Void)? = nil) {
        self.createConversationAction = createConversationAction
    }

    var body: some View {
        SessionFolderBrowserView(
            folderID: nil,
            isRoot: true,
            createConversationAction: createConversationAction
        )
    }
}


struct SessionMergedEntryWithRank {
    let rank: Int
    let entry: SessionMergedEntry
}


enum SessionMergedEntry: Identifiable {
    case folder(SessionFolder)
    case session(ChatSession)

    var id: String {
        switch self {
        case .folder(let folder):
            return "folder-\(folder.id.uuidString)"
        case .session(let session):
            return "session-\(session.id.uuidString)"
        }
    }
}


struct SessionMoveFolderOption: Identifiable {
    let id: UUID
    let title: String
}


struct BatchSelectableFolderRow: View {
    let folder: SessionFolder
    let sessionCount: Int
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Label {
                        Text(folder.name)
                    } icon: {
                        Image(systemName: "folder")
                            .foregroundStyle(Color.accentColor)
                    }
                    .etFont(.system(size: 16, weight: .medium))

                    Text(String(format: NSLocalizedString("%d 个会话", comment: ""), sessionCount))
                        .etFont(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}


struct BatchSelectableSessionRow: View {
    let session: ChatSession
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                SessionListRowContent(
                    title: session.name,
                    subtitle: session.topicPrompt,
                    footnote: nil,
                    isCurrent: false,
                    isRunning: false
                )
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Row

struct SessionRow: View {
    let session: ChatSession
    let isCurrent: Bool
    let isRunning: Bool
    let isEditing: Bool
    @Binding var draftName: String
    let currentFolderID: UUID?
    let moveOptions: [SessionMoveFolderOption]
    let searchSummary: String?
    let locationSummary: String?

    let onCommit: (String) -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    let onBranch: (Bool) -> Void
    let onMoveToFolder: (UUID?) -> Void
    let onDeleteLastMessage: () -> Void
    let onDelete: () -> Void
    let onCancelRename: () -> Void
    let onInfo: () -> Void
    let onSendToCompanion: () -> Void

    @FocusState var focused: Bool

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
                SessionListRowContent(
                    title: session.name,
                    subtitle: primarySubtitle,
                    footnote: secondarySubtitle,
                    isCurrent: isCurrent,
                    isRunning: isRunning
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

            Menu {
                Button {
                    onMoveToFolder(nil)
                } label: {
                    Label(NSLocalizedString("未分类", comment: ""), systemImage: currentFolderID == nil ? "checkmark" : "tray")
                }

                ForEach(moveOptions) { option in
                    Button {
                        onMoveToFolder(option.id)
                    } label: {
                        Label(option.title, systemImage: currentFolderID == option.id ? "checkmark" : "folder")
                    }
                }
            } label: {
                Label(NSLocalizedString("移动到文件夹", comment: ""), systemImage: "folder")
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

            Button {
                onSendToCompanion()
            } label: {
                Label(NSLocalizedString("发送到 Apple Watch", comment: ""), systemImage: "applewatch")
            }
            .disabled(session.isTemporary)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(NSLocalizedString("删除会话", comment: ""), systemImage: "trash")
            }
        }
    }

    func commit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }

    var primarySubtitle: String? {
        if let searchSummary, !searchSummary.isEmpty {
            return searchSummary
        }
        if let topic = session.topicPrompt, !topic.isEmpty {
            return topic
        }
        return locationSummary
    }

    var secondarySubtitle: String? {
        guard searchSummary == nil || searchSummary?.isEmpty == true else {
            return locationSummary
        }
        if let topic = session.topicPrompt, !topic.isEmpty {
            return locationSummary
        }
        return nil
    }
}


struct SessionListRowContent: View {
    let title: String
    let subtitle: String?
    let footnote: String?
    let isCurrent: Bool
    let isRunning: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .etFont(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .etFont(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let footnote, !footnote.isEmpty {
                    Text(footnote)
                        .etFont(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            trailingStatus
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    var trailingStatus: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if isRunning {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
            }

            if isCurrent {
                Image(systemName: "checkmark")
                    .etFont(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(minWidth: 22, alignment: .topTrailing)
    }
}


// MARK: - Session Info

struct SessionInfoPayload: Identifiable {
    let id = UUID()
    let session: ChatSession
    let messageCount: Int
    let isCurrent: Bool
}


struct SessionInfoSheet: View {
    let payload: SessionInfoPayload
    @Environment(\.dismiss) var dismiss

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
