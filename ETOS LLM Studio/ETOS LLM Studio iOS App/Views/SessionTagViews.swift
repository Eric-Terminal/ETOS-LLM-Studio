// ============================================================================
// SessionTagViews.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 会话标签的 Apple 风格固定色板、标签展示与管理界面。
// ============================================================================

import Shared
import SwiftUI
import UIKit

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
    let onCreate: (String, SessionTagColor?) -> SessionTag?
    let onUpdate: (SessionTag, String, SessionTagColor?) -> Void
    let onDelete: (SessionTag) -> Void
    let onSetTagIDs: ([UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTagIDs: Set<UUID>
    @State private var isAddingTag = false
    @State private var draftTagName = ""
    @State private var draftTagColor: SessionTagColor? = .red
    @FocusState private var isDraftFocused: Bool

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
        onDelete: @escaping (SessionTag) -> Void,
        onSetTagIDs: @escaping ([UUID]) -> Void
    ) {
        self.session = session
        self.tags = tags
        self.onCreate = onCreate
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.onSetTagIDs = onSetTagIDs
        _selectedTagIDs = State(initialValue: Set(session.tagIDs))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(assignmentTags) { tag in
                        SessionTagAssignmentRow(
                            tag: tag,
                            isSelected: selectedTagIDs.contains(tag.id),
                            onToggle: {
                                toggle(tag.id)
                            },
                            onColorChange: { color in
                                onUpdate(tag, tag.name, color)
                            }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !tag.isSystemColorTag {
                                Button(role: .destructive) {
                                    delete(tag)
                                } label: {
                                    Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                                }
                            }
                        }
                    }

                    if isAddingTag {
                        SessionTagDraftAssignmentRow(
                            name: $draftTagName,
                            color: $draftTagColor,
                            isFocused: $isDraftFocused,
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
                            .foregroundStyle(.primary, .green)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(NSLocalizedString("标签", comment: "Session tag assignment title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        commitDraftTagIfNeeded()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(NSLocalizedString("关闭", comment: "Close sheet"))
                }
            }
        }
        .onDisappear {
            commitDraftTagIfNeeded()
        }
        .onChange(of: isAddingTag) { _, isAdding in
            guard isAdding else { return }
            DispatchQueue.main.async {
                isDraftFocused = true
            }
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
        if isAddingTag {
            isDraftFocused = true
            return
        }
        draftTagName = ""
        draftTagColor = .red
        isAddingTag = true
    }

    private func delete(_ tag: SessionTag) {
        guard !tag.isSystemColorTag else { return }
        selectedTagIDs.remove(tag.id)
        onDelete(tag)
        onSetTagIDs(orderedSelectedTagIDs())
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

struct SessionTagAssignmentRow: View {
    let tag: SessionTag
    let isSelected: Bool
    let onToggle: () -> Void
    let onColorChange: (SessionTagColor?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))

                    Text(tag.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if tag.isSystemColorTag {
                SessionTagColorDot(color: tag.color, size: 28)
            } else {
                SessionTagColorMenu(selectedColor: Binding(
                    get: { tag.color },
                    set: { onColorChange($0) }
                ), size: 28)
            }
        }
        .accessibilityLabel(tag.name)
    }
}

struct SessionTagDraftAssignmentRow: View {
    @Binding var name: String
    @Binding var color: SessionTagColor?
    let isFocused: FocusState<Bool>.Binding
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)

            TextField(NSLocalizedString("标签名称", comment: "Session tag name field"), text: $name)
                .focused(isFocused)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .onSubmit(onCommit)

            Spacer()

            SessionTagColorMenu(selectedColor: $color, size: 28)
        }
    }
}

struct SessionTagColorMenu: View {
    @Binding var selectedColor: SessionTagColor?
    var size: CGFloat

    var body: some View {
        SessionTagColorMenuButton(selectedColor: $selectedColor, size: size)
            .frame(width: size, height: size)
            .accessibilityLabel(NSLocalizedString("颜色", comment: "Session tag color menu"))
    }
}

private struct SessionTagColorMenuButton: UIViewRepresentable {
    @Binding var selectedColor: SessionTagColor?
    let size: CGFloat

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = false
        button.tintColor = .label
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.setImage(SessionTagColorImageFactory.image(for: selectedColor, size: size, circleDiameter: size), for: .normal)
        button.menu = UIMenu(children: colorActions())
    }

    private func colorActions() -> [UIAction] {
        [colorAction(nil, title: NSLocalizedString("无", comment: "No color option"))]
            + SessionTagColor.allCases.map { color in
                colorAction(color, title: color.localizedName)
            }
    }

    private func colorAction(_ color: SessionTagColor?, title: String) -> UIAction {
        UIAction(
            title: title,
            image: SessionTagColorImageFactory.image(for: color, size: 18, circleDiameter: 12),
            state: selectedColor == color ? .on : .off
        ) { _ in
            selectedColor = color
        }
    }
}

private enum SessionTagColorImageFactory {
    static func image(for color: SessionTagColor?, size: CGFloat, circleDiameter: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let diameter = min(circleDiameter, size)
        let lineWidth = max(diameter * 0.08, 1)
        let strokedInset = color == nil ? lineWidth / 2 : 0
        let circleRect = CGRect(
            x: (size - diameter) / 2 + strokedInset,
            y: (size - diameter) / 2 + strokedInset,
            width: diameter - strokedInset * 2,
            height: diameter - strokedInset * 2
        )

        return renderer.image { context in
            if let color {
                color.menuUIColor.setFill()
                context.cgContext.fillEllipse(in: circleRect)
                return
            }

            UIColor.secondaryLabel.setStroke()
            context.cgContext.setLineWidth(lineWidth)
            context.cgContext.strokeEllipse(in: circleRect)
        }
        .withRenderingMode(.alwaysOriginal)
    }
}

private extension SessionTagColor {
    var menuUIColor: UIColor {
        switch self {
        case .red:
            return .systemRed
        case .orange:
            return .systemOrange
        case .yellow:
            return .systemYellow
        case .green:
            return .systemGreen
        case .blue:
            return .systemBlue
        case .purple:
            return .systemPurple
        case .gray:
            return .systemGray
        }
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
