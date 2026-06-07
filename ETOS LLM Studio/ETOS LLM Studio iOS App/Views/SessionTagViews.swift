// ============================================================================
// SessionTagViews.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 会话标签的 Apple 风格固定色板、标签展示与管理界面。
// ============================================================================

import Shared
import SwiftUI

extension SessionTagColor {
    var uiColor: Color {
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

struct SessionTagColorDot: View {
    let color: SessionTagColor?
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(color?.uiColor ?? Color.clear)
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .strokeBorder(color == nil ? Color.secondary : Color.clear, lineWidth: 1.2)
            }
            .accessibilityHidden(true)
    }
}

struct SessionTagPill: View {
    let tag: SessionTag

    var body: some View {
        if tag.isSystemColorTag {
            SessionTagColorDot(color: tag.color, size: 8)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .accessibilityLabel(tag.name)
        } else {
            HStack(spacing: 5) {
                SessionTagColorDot(color: tag.color, size: 8)
                Text(tag.name)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((tag.color?.uiColor ?? Color.secondary).opacity(0.12), in: Capsule())
            .foregroundStyle(.secondary)
        }
    }
}

struct SessionTagInlineList: View {
    let tags: [SessionTag]

    var body: some View {
        if !tags.isEmpty {
            SessionTagFlowLayout(spacing: 6, rowSpacing: 4) {
                ForEach(tags) { tag in
                    SessionTagPill(tag: tag)
                }
            }
        }
    }
}

struct SessionTagRowLabel: View {
    let tag: SessionTag

    var body: some View {
        HStack(spacing: 8) {
            SessionTagColorDot(color: tag.color, size: 11)
            Text(tag.name)
                .lineLimit(1)
        }
    }
}

struct SessionTagManagementView: View {
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
        NavigationStack {
            Form {
                Section(header: Text(NSLocalizedString("新建标签", comment: "Create session tag section"))) {
                    TextField(NSLocalizedString("标签名称", comment: "Session tag name field"), text: $draftName)
                    SessionTagColorSelection(selectedColor: $draftColor)
                    Button {
                        commitCreate()
                    } label: {
                        Label(NSLocalizedString("添加标签", comment: "Add session tag button"), systemImage: "plus")
                    }
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section(
                    header: Text(NSLocalizedString("标签", comment: "Session tags section")),
                    footer: Text(NSLocalizedString("颜色使用固定系统色板；无颜色会显示为空心圆点。", comment: "Session tag palette footer"))
                ) {
                    if editableTags.isEmpty {
                        Text(NSLocalizedString("暂无标签", comment: "No session tags"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(editableTags) { tag in
                            Button {
                                editingTag = tag
                            } label: {
                                HStack {
                                    SessionTagRowLabel(tag: tag)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) { dismiss() }
                }
            }
            .sheet(item: $editingTag) { tag in
                SessionTagEditView(
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
    }

    private func commitCreate() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed, draftColor)
        draftName = ""
        draftColor = nil
    }
}

struct SessionTagEditView: View {
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
        NavigationStack {
            Form {
                Section(header: Text(NSLocalizedString("标签", comment: "Session tag section"))) {
                    TextField(NSLocalizedString("标签名称", comment: "Session tag name field"), text: $draftName)
                    SessionTagColorSelection(selectedColor: $draftColor)
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
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }
                }
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
}

struct SessionTagAssignmentView: View {
    let session: ChatSession
    let tags: [SessionTag]
    let onSetTagIDs: ([UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTagIDs: Set<UUID>

    private var editableTags: [SessionTag] {
        tags.filter { !$0.isSystemColorTag }
    }

    private var preservedSystemTagIDs: [UUID] {
        let systemTagIDs = Set(tags.filter(\.isSystemColorTag).map(\.id))
        return session.tagIDs.filter { systemTagIDs.contains($0) }
    }

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
        NavigationStack {
            Form {
                Section(header: Text(NSLocalizedString("标签", comment: "Session tag assignment section"))) {
                    if editableTags.isEmpty {
                        Text(NSLocalizedString("暂无标签", comment: "No session tags"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(editableTags) { tag in
                            Toggle(isOn: binding(for: tag.id)) {
                                SessionTagRowLabel(tag: tag)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("编辑会话标签", comment: "Edit session tags title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        onSetTagIDs(orderedSelectedTagIDs())
                        dismiss()
                    }
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
        preservedSystemTagIDs + editableTags.map(\.id).filter { selectedTagIDs.contains($0) }
    }
}

struct SessionTagQuickColorPalette: View {
    let selectedColors: Set<SessionTagColor>
    let onSelect: (SessionTagColor?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            colorButton(nil, title: NSLocalizedString("无颜色", comment: "No session tag color"))
            ForEach(SessionTagColor.allCases) { color in
                colorButton(color, title: color.localizedName)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private func colorButton(_ color: SessionTagColor?, title: String) -> some View {
        let isSelected = color.map { selectedColors.contains($0) } ?? selectedColors.isEmpty
        return Button {
            onSelect(color)
        } label: {
            ZStack {
                Circle()
                    .fill(color?.uiColor ?? Color.clear)
                Circle()
                    .strokeBorder(color == nil ? Color.secondary : Color.primary.opacity(0.2), lineWidth: color == nil ? 1.4 : 0.8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(color == nil ? Color.primary : Color.white)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .accessibilityLabel(title)
    }
}

struct SessionTagColorSelection: View {
    @Binding var selectedColor: SessionTagColor?

    private let columns = [
        GridItem(.adaptive(minimum: 72), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            colorButton(nil, title: NSLocalizedString("无颜色", comment: "No session tag color"))
            ForEach(SessionTagColor.allCases) { color in
                colorButton(color, title: color.localizedName)
            }
        }
        .padding(.vertical, 4)
    }

    private func colorButton(_ color: SessionTagColor?, title: String) -> some View {
        Button {
            selectedColor = color
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedColor == color ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedColor == color ? Color.accentColor : Color.secondary)
                SessionTagColorDot(color: color, size: 10)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct SessionTagFlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0, currentX + spacing + size.width > maxWidth {
                widestRow = max(widestRow, currentX)
                totalHeight += currentRowHeight + rowSpacing
                currentX = 0
                currentRowHeight = 0
            }
            currentX += (currentX == 0 ? 0 : spacing) + size.width
            currentRowHeight = max(currentRowHeight, size.height)
        }

        widestRow = max(widestRow, currentX)
        totalHeight += currentRowHeight
        return CGSize(width: min(widestRow, maxWidth), height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX, currentX + spacing + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += currentRowHeight + rowSpacing
                currentRowHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(size)
            )
            currentX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}
