// ============================================================================
// SessionTagViews.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// watchOS 会话标签的固定色板、展示与管理界面。
// ============================================================================

import Shared
import SwiftUI

extension SessionTagColor {
    var watchColor: Color {
        switch self {
        case .red:
            return .red
        case .orange:
            return .orange
        case .yellow:
            return .yellow
        case .green:
            return .green
        case .blue:
            return .blue
        case .purple:
            return .purple
        case .gray:
            return .gray
        }
    }
}

struct WatchSessionTagDot: View {
    let color: SessionTagColor?
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color?.watchColor ?? Color.clear)
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .strokeBorder(color == nil ? Color.secondary : Color.clear, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

struct WatchSessionTagInlineList: View {
    let tags: [SessionTag]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 5) {
                ForEach(tags.prefix(3)) { tag in
                    HStack(spacing: 3) {
                        WatchSessionTagDot(color: tag.color)
                        Text(tag.name)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if tags.count > 3 {
                    Text("+\(tags.count - 3)")
                        .etFont(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct WatchSessionTagRowLabel: View {
    let tag: SessionTag

    var body: some View {
        HStack(spacing: 6) {
            WatchSessionTagDot(color: tag.color, size: 9)
            Text(tag.name)
                .lineLimit(1)
        }
    }
}

struct WatchSessionTagManagementView: View {
    let tags: [SessionTag]
    let onCreate: (String, SessionTagColor?) -> Void
    let onUpdate: (SessionTag, String, SessionTagColor?) -> Void
    let onDelete: (SessionTag) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftName = ""
    @State private var draftColor: SessionTagColor?
    @State private var editingTag: SessionTag?

    var body: some View {
        List {
            Section(header: Text(NSLocalizedString("新建标签", comment: "Create session tag section"))) {
                TextField(NSLocalizedString("标签名称", comment: "Session tag name field"), text: $draftName)
                WatchSessionTagColorSelection(selectedColor: $draftColor)
                Button {
                    commitCreate()
                } label: {
                    Label(NSLocalizedString("添加标签", comment: "Add session tag button"), systemImage: "plus")
                }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section(header: Text(NSLocalizedString("标签", comment: "Session tags section"))) {
                if tags.isEmpty {
                    Text(NSLocalizedString("暂无标签", comment: "No session tags"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tags) { tag in
                        Button {
                            editingTag = tag
                        } label: {
                            WatchSessionTagRowLabel(tag: tag)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                onDelete(tag)
                            } label: {
                                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("管理标签", comment: "Manage session tags title"))
        .sheet(item: $editingTag) { tag in
            WatchSessionTagEditView(
                tag: tag,
                onSave: { name, color in
                    onUpdate(tag, name, color)
                    editingTag = nil
                },
                onDelete: {
                    onDelete(tag)
                    editingTag = nil
                }
            )
        }
    }

    private func commitCreate() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed, draftColor)
        draftName = ""
        draftColor = nil
    }
}

struct WatchSessionTagEditView: View {
    let tag: SessionTag
    let onSave: (String, SessionTagColor?) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftName: String
    @State private var draftColor: SessionTagColor?

    init(
        tag: SessionTag,
        onSave: @escaping (String, SessionTagColor?) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.tag = tag
        self.onSave = onSave
        self.onDelete = onDelete
        _draftName = State(initialValue: tag.name)
        _draftColor = State(initialValue: tag.color)
    }

    var body: some View {
        List {
            Section(header: Text(NSLocalizedString("标签", comment: "Session tag section"))) {
                TextField(NSLocalizedString("标签名称", comment: "Session tag name field"), text: $draftName)
                WatchSessionTagColorSelection(selectedColor: $draftColor)
            }

            Section {
                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Label(NSLocalizedString("删除标签", comment: "Delete session tag button"), systemImage: "trash")
                }
            }
        }
        .navigationTitle(NSLocalizedString("编辑标签", comment: "Edit session tag title"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "")) {
                    onSave(draftName, draftColor)
                    dismiss()
                }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

struct WatchSessionTagAssignmentView: View {
    let session: ChatSession
    let tags: [SessionTag]
    let onSetTagIDs: ([UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTagIDs: Set<UUID>

    init(
        session: ChatSession,
        tags: [SessionTag],
        onSetTagIDs: @escaping ([UUID]) -> Void
    ) {
        self.session = session
        self.tags = tags
        self.onSetTagIDs = onSetTagIDs
        _selectedTagIDs = State(initialValue: Set(session.tagIDs))
    }

    var body: some View {
        List {
            Section(header: Text(NSLocalizedString("标签", comment: "Session tag assignment section"))) {
                if tags.isEmpty {
                    Text(NSLocalizedString("暂无标签", comment: "No session tags"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tags) { tag in
                        Toggle(isOn: binding(for: tag.id)) {
                            WatchSessionTagRowLabel(tag: tag)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("编辑标签", comment: "Edit session tag title"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("完成", comment: "")) {
                    onSetTagIDs(orderedSelectedTagIDs())
                    dismiss()
                }
            }
        }
    }

    private func binding(for tagID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedTagIDs.contains(tagID) },
            set: { isSelected in
                if isSelected {
                    selectedTagIDs.insert(tagID)
                } else {
                    selectedTagIDs.remove(tagID)
                }
            }
        )
    }

    private func orderedSelectedTagIDs() -> [UUID] {
        tags.map(\.id).filter { selectedTagIDs.contains($0) }
    }
}

struct WatchSessionTagColorSelection: View {
    @Binding var selectedColor: SessionTagColor?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            colorButton(nil, title: NSLocalizedString("无颜色", comment: "No session tag color"))
            ForEach(SessionTagColor.allCases) { color in
                colorButton(color, title: color.localizedName)
            }
        }
        .buttonStyle(.plain)
    }

    private func colorButton(_ color: SessionTagColor?, title: String) -> some View {
        Button {
            selectedColor = color
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedColor == color ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedColor == color ? Color.accentColor : Color.secondary)
                WatchSessionTagDot(color: color, size: 9)
                Text(title)
                    .etFont(.caption)
                    .lineLimit(1)
            }
        }
    }
}
