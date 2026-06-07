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
                    if tag.isSystemColorTag {
                        WatchSessionTagDot(color: tag.color)
                            .accessibilityLabel(tag.name)
                    } else {
                        HStack(spacing: 3) {
                            WatchSessionTagDot(color: tag.color)
                            Text(tag.name)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
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

    private var editableTags: [SessionTag] {
        tags.filter { !$0.isSystemColorTag }
    }

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
                if editableTags.isEmpty {
                    Text(NSLocalizedString("暂无标签", comment: "No session tags"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(editableTags) { tag in
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
    let onCreate: (String, SessionTagColor?) -> SessionTag?
    let onUpdate: (SessionTag, String, SessionTagColor?) -> Void
    let onSetTagIDs: ([UUID]) -> Void

    @State private var selectedTagIDs: Set<UUID>
    @State private var isAddingTag = false
    @State private var draftTagName = ""
    @State private var draftTagColor: SessionTagColor? = .red

    private var customTags: [SessionTag] {
        tags.filter { !$0.isSystemColorTag }
    }

    private var systemColorTags: [SessionTag] {
        SessionTagColor.allCases.map { SessionTag.systemColorTag(for: $0) }
    }

    private var assignmentTags: [SessionTag] {
        systemColorTags + customTags
    }

    init(
        session: ChatSession,
        tags: [SessionTag],
        onCreate: @escaping (String, SessionTagColor?) -> SessionTag?,
        onUpdate: @escaping (SessionTag, String, SessionTagColor?) -> Void,
        onSetTagIDs: @escaping ([UUID]) -> Void
    ) {
        self.session = session
        self.tags = tags
        self.onCreate = onCreate
        self.onUpdate = onUpdate
        self.onSetTagIDs = onSetTagIDs
        _selectedTagIDs = State(initialValue: Set(session.tagIDs))
    }

    var body: some View {
        List {
            Section(header: Text(NSLocalizedString("标签", comment: "Session tag assignment section"))) {
                ForEach(assignmentTags) { tag in
                    WatchSessionTagAssignmentRow(
                        tag: tag,
                        isSelected: selectedTagIDs.contains(tag.id),
                        onToggle: {
                            toggle(tag.id)
                        },
                        onColorChange: { color in
                            onUpdate(tag, tag.name, color)
                        }
                    )
                }

                if isAddingTag {
                    WatchSessionTagDraftAssignmentRow(
                        name: $draftTagName,
                        color: $draftTagColor,
                        onCommit: {
                            commitDraftTagIfNeeded()
                        }
                    )
                }
            }

            Section {
                Button {
                    beginAddingTag()
                } label: {
                    Label(NSLocalizedString("添加新标签...", comment: "Add a new session tag from assignment sheet"), systemImage: "plus.circle.fill")
                }
                .foregroundStyle(.green)
            }
        }
        .navigationTitle(NSLocalizedString("标签", comment: "Session tag assignment title"))
        .onDisappear {
            commitDraftTagIfNeeded()
        }
    }

    private func toggle(_ tagID: UUID) {
        commitDraftTagIfNeeded()
        if selectedTagIDs.contains(tagID) {
            selectedTagIDs.remove(tagID)
        } else {
            selectedTagIDs.insert(tagID)
        }
        onSetTagIDs(orderedSelectedTagIDs())
    }

    private func orderedSelectedTagIDs() -> [UUID] {
        let orderedKnownIDs = assignmentTags.map(\.id).filter { selectedTagIDs.contains($0) }
        let knownIDs = Set(assignmentTags.map(\.id))
        let trailingIDs = selectedTagIDs
            .filter { !knownIDs.contains($0) }
            .sorted { $0.uuidString < $1.uuidString }
        return orderedKnownIDs + trailingIDs
    }

    private func beginAddingTag() {
        guard !isAddingTag else { return }
        draftTagName = ""
        draftTagColor = .red
        isAddingTag = true
    }

    @discardableResult
    private func commitDraftTagIfNeeded() -> SessionTag? {
        let trimmedName = draftTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAddingTag, !trimmedName.isEmpty else { return nil }
        guard let tag = onCreate(trimmedName, draftTagColor) else { return nil }

        selectedTagIDs.insert(tag.id)
        isAddingTag = false
        draftTagName = ""
        draftTagColor = .red
        onSetTagIDs(orderedSelectedTagIDs())
        return tag
    }
}

struct WatchSessionTagAssignmentRow: View {
    let tag: SessionTag
    let isSelected: Bool
    let onToggle: () -> Void
    let onColorChange: (SessionTagColor?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                    Text(tag.name)
                        .etFont(.body)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if tag.isSystemColorTag {
                WatchSessionTagDot(color: tag.color, size: 16)
            } else {
                WatchSessionTagColorLink(selectedColor: Binding(
                    get: { tag.color },
                    set: { onColorChange($0) }
                ), size: 16)
            }
        }
        .accessibilityLabel(tag.name)
    }
}

struct WatchSessionTagDraftAssignmentRow: View {
    @Binding var name: String
    @Binding var color: SessionTagColor?
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)

            TextField(NSLocalizedString("标签名称", comment: "Session tag name field"), text: $name)
                .submitLabel(.done)
                .onSubmit(onCommit)

            WatchSessionTagColorLink(selectedColor: $color, size: 16)
        }
    }
}

struct WatchSessionTagColorLink: View {
    @Binding var selectedColor: SessionTagColor?
    var size: CGFloat

    var body: some View {
        NavigationLink {
            WatchSessionTagColorPickerView(selectedColor: $selectedColor)
        } label: {
            WatchSessionTagDot(color: selectedColor, size: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("颜色", comment: "Session tag color picker"))
    }
}

struct WatchSessionTagColorPickerView: View {
    @Binding var selectedColor: SessionTagColor?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            colorButton(nil, title: NSLocalizedString("无", comment: "No color option"))
            ForEach(SessionTagColor.allCases) { color in
                colorButton(color, title: color.localizedName)
            }
        }
        .navigationTitle(NSLocalizedString("颜色", comment: "Session tag color picker title"))
    }

    private func colorButton(_ color: SessionTagColor?, title: String) -> some View {
        Button {
            selectedColor = color
            dismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedColor == color ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedColor == color ? Color.accentColor : Color.secondary)
                WatchSessionTagDot(color: color, size: 12)
                Text(title)
                    .etFont(.body)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
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
