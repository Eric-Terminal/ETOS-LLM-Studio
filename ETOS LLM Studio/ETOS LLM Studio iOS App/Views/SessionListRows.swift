// ============================================================================
// SessionListRows.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供 iOS 会话列表的行组件、批量选择行与会话信息 Sheet。
// 行采用卡片样式（圆角 14、淡描边、当前会话三重强调），适合分组浏览。
// ============================================================================

import Foundation
import Shared
import SwiftUI

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

// MARK: - 通用卡片容器

/// 会话/文件夹行的统一卡片背景，包含当前态高亮、左侧强调条与描边。
struct SessionRowCard<Content: View>: View {
    let isCurrent: Bool
    let content: () -> Content

    init(isCurrent: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.isCurrent = isCurrent
        self.content = content
    }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        isCurrent
                            ? Color.accentColor.opacity(0.10)
                            : Color(.secondarySystemGroupedBackground)
                    )
            }
            .overlay(alignment: .leading) {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, 10)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isCurrent
                            ? Color.accentColor.opacity(0.35)
                            : Color(.separator).opacity(0.35),
                        lineWidth: 0.5
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 分组标题

/// 列表分组标题（文件夹 / 会话 / 搜索结果），样式贴近邮件 App。
struct SessionGroupHeader: View {
    let title: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 批量选择行

struct BatchSelectableFolderRow: View {
    let folder: SessionFolder
    let sessionCount: Int
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            SessionRowCard(isCurrent: false) {
                HStack(alignment: .center, spacing: 12) {
                    selectionIndicator
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                            Text(folder.name)
                                .etFont(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        Text(String(format: NSLocalizedString("%d 个会话", comment: ""), sessionCount))
                            .etFont(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var selectionIndicator: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
    }
}

struct BatchSelectableSessionRow: View {
    let session: ChatSession
    let tags: [SessionTag]
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            SessionRowCard(isCurrent: false) {
                HStack(alignment: .center, spacing: 12) {
                    selectionIndicator
                    SessionListRowContentBody(
                        title: session.name,
                        subtitle: session.topicPrompt,
                        footnote: nil,
                        tags: tags,
                        isCurrent: false,
                        isRunning: false
                    )
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var selectionIndicator: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
    }
}

// MARK: - 普通会话行

struct SessionRow: View {
    let session: ChatSession
    let isCurrent: Bool
    let isRunning: Bool
    let isEditing: Bool
    @Binding var draftName: String
    let currentFolderID: UUID?
    let moveOptions: [SessionMoveFolderOption]
    let tags: [SessionTag]
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
    let onEditTags: () -> Void
    let onToggleQuickColor: (SessionTagColor?) -> Void
    let onSendToCompanion: () -> Void

    @FocusState private var focused: Bool

    private var quickColorMarkers: Set<SessionTagColor> {
        Set(tags.compactMap(\.systemColor))
    }

    var body: some View {
        SessionRowCard(isCurrent: isCurrent) {
            if isEditing {
                editingBody
            } else {
                normalBody
            }
        }
        .contextMenu {
            contextMenuContent
        }
    }

    private var normalBody: some View {
        SessionListRowContentBody(
            title: session.name,
            subtitle: primarySubtitle,
            footnote: secondarySubtitle,
            tags: tags,
            isCurrent: isCurrent,
            isRunning: isRunning
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }

    private var editingBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(NSLocalizedString("会话名称", comment: ""), text: $draftName)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { commit() }
                .onAppear { focused = true }

            HStack(spacing: 8) {
                Button(NSLocalizedString("保存", comment: "")) {
                    commit()
                }
                .buttonStyle(.borderedProminent)

                Button(NSLocalizedString("取消", comment: "")) {
                    onCancelRename()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
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
            onEditTags()
        } label: {
            Label(NSLocalizedString("编辑标签", comment: "Edit session tags action"), systemImage: "tag")
        }

        Divider()

        SessionTagQuickColorPalette(
            selectedColors: quickColorMarkers,
            onSelect: onToggleQuickColor
        )

        Divider()

        Menu {
            Button {
                onMoveToFolder(nil)
            } label: {
                Label(
                    NSLocalizedString("未分类", comment: ""),
                    systemImage: currentFolderID == nil ? "checkmark" : "tray"
                )
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

    private func commit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }

    private var primarySubtitle: String? {
        if let searchSummary, !searchSummary.isEmpty {
            return searchSummary
        }
        if let topic = session.topicPrompt, !topic.isEmpty {
            return topic
        }
        return locationSummary
    }

    private var secondarySubtitle: String? {
        guard searchSummary == nil || searchSummary?.isEmpty == true else {
            return locationSummary
        }
        if let topic = session.topicPrompt, !topic.isEmpty {
            return locationSummary
        }
        return nil
    }
}

// MARK: - 行文本主体（标题 + 副信息 + 状态徽标）

/// 卡片内部的文本结构，独立于卡片外壳，便于复用。
struct SessionListRowContentBody: View {
    let title: String
    let subtitle: String?
    let footnote: String?
    let tags: [SessionTag]
    let isCurrent: Bool
    let isRunning: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .etFont(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(2)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .etFont(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let footnote, !footnote.isEmpty {
                    Text(footnote)
                        .etFont(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                SessionTagInlineList(tags: tags)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingStatus
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if isRunning {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text(NSLocalizedString("生成中", comment: ""))
                    .etFont(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.green)
            }
        } else if isCurrent {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
    }
}

/// 兼容性外壳：保持旧的调用入口（搜索结果行依然使用此组件）。
/// 自带头像 + 卡片背景，调用方仅需关心文本字段。
struct SessionListRowContent: View {
    let title: String
    let subtitle: String?
    let footnote: String?
    let tags: [SessionTag]
    let isCurrent: Bool
    let isRunning: Bool

    var body: some View {
        SessionRowCard(isCurrent: isCurrent) {
            SessionListRowContentBody(
                title: title,
                subtitle: subtitle,
                footnote: footnote,
                tags: tags,
                isCurrent: isCurrent,
                isRunning: isRunning
            )
        }
    }
}

struct SessionSearchResultRowContent: View {
    let title: String
    let preview: String
    let isCurrent: Bool
    let isRunning: Bool
    let titleColor: Color
    let previewColor: Color
    let selectedColor: Color

    init(
        title: String,
        preview: String,
        isCurrent: Bool,
        isRunning: Bool = false,
        titleColor: Color = .primary,
        previewColor: Color = .secondary,
        selectedColor: Color = .accentColor
    ) {
        self.title = title
        self.preview = preview
        self.isCurrent = isCurrent
        self.isRunning = isRunning
        self.titleColor = titleColor
        self.previewColor = previewColor
        self.selectedColor = selectedColor
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .etFont(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isCurrent ? selectedColor : titleColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(preview)
                    .etFont(.system(size: 12.5))
                    .foregroundStyle(previewColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingStatus
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if isRunning {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text(NSLocalizedString("生成中", comment: ""))
                    .etFont(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.green)
            }
            .padding(.top, 1)
        } else if isCurrent {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selectedColor)
                .padding(.top, 1)
        }
    }
}

// MARK: - 会话信息 Sheet

struct SessionInfoPayload: Identifiable {
    let id = UUID()
    let session: ChatSession
    let messageCount: Int
    let isCurrent: Bool
}

struct SessionInfoSheet: View {
    let payload: SessionInfoPayload
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
