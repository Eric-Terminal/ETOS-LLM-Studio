// ============================================================================
// WatchMessageTextSelectionView.swift
// ============================================================================
// watchOS 消息文字选择页：触摸拖动建立连续选区，提交后回填聊天输入框。
// ============================================================================

import SwiftUI
import Foundation
import WatchKit
import ETOSCore

struct WatchMessageTextSelectionView: View {
    let message: ChatMessage
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var content: WatchSelectableMessageContent?
    @State private var geometryIndex = WatchTextSelectionGeometryIndex.empty
    @State private var selectionAnchorTokenID: Int?
    @State private var selectionEndTokenID: Int?
    @State private var isDraggingSelection = false
    @State private var viewportHeight: CGFloat = 0
    @State private var autoScrollDirection: WatchTextSelectionAutoScrollDirection?
    @State private var autoScrollStrength: CGFloat = 0
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var showsFillFormatDialog = false

    private let viewportCoordinateSpaceName = "watchMessageTextSelectionViewport"

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("拖动选择文字；停留在顶部或底部可继续滚动，转动数码表冠可浏览全文。", comment: "Watch text selection guidance"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)

                    if let content {
                        selectableText(content, scrollProxy: scrollProxy)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
            .coordinateSpace(name: viewportCoordinateSpaceName)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: WatchTextSelectionViewportHeightKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .onPreferenceChange(WatchTextSelectionViewportHeightKey.self) { height in
                viewportHeight = height
            }
        }
        .navigationTitle(NSLocalizedString("选定文字", comment: "Message text selection title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel(NSLocalizedString("返回", comment: "Return from text selection"))
            }

            ToolbarItem(placement: .confirmationAction) {
                if selectedTokenRange != nil {
                    Button {
                        commitSelection()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(NSLocalizedString("完成", comment: "Commit selected text to input"))
                } else {
                    Button {
                        showsFillFormatDialog = true
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel(NSLocalizedString("复制内容", comment: "Fill full message content into input"))
                    .disabled(content == nil)
                }
            }
        }
        .confirmationDialog(
            NSLocalizedString("填充格式", comment: "Watch input fill format dialog title"),
            isPresented: $showsFillFormatDialog,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("填充 Markdown", comment: "Fill Markdown into watch chat input")) {
                commit(message.content)
            }
            Button(NSLocalizedString("填充纯文本", comment: "Fill plain text into watch chat input")) {
                commit(content?.plainText ?? message.content)
            }
            Button(NSLocalizedString("取消", comment: "Cancel input fill format selection"), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("选择填充到输入框的格式。", comment: "Watch input fill format guidance"))
        }
        .task(id: message.id) {
            let markdown = message.content
            let prepared = await Task.detached(priority: .userInitiated) {
                WatchSelectableMessageContent.prepare(markdown: markdown)
            }.value
            guard !Task.isCancelled else { return }
            content = prepared
        }
        .onDisappear {
            stopAutoScroll()
        }
    }

    @ViewBuilder
    private func selectableText(
        _ content: WatchSelectableMessageContent,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(content.paragraphTokenRanges.indices, id: \.self) { paragraphIndex in
                let tokenRange = content.paragraphTokenRanges[paragraphIndex]
                if tokenRange.isEmpty {
                    Text(" ")
                        .etFont(.body)
                        .accessibilityHidden(true)
                } else {
                    WatchSelectableTextFlowLayout {
                        ForEach(tokenRange, id: \.self) { tokenID in
                            selectableToken(content.tokens[tokenID])
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .highPriorityGesture(selectionGesture(scrollProxy: scrollProxy))
        .onPreferenceChange(WatchTextSelectionTokenFramesKey.self) { frames in
            geometryIndex = WatchTextSelectionGeometryIndex(frames: frames)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(content.plainText))
    }

    private func selectableToken(_ token: WatchSelectableMessageToken) -> some View {
        let isSelected = selectedTokenRange?.contains(token.id) == true
        return Text(token.text)
            .etFont(.body, sampleText: token.text)
            .fixedSize()
            .id(token.id)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.accentColor.opacity(0.36))
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: WatchTextSelectionTokenFramesKey.self,
                        value: [token.id: proxy.frame(in: .named(viewportCoordinateSpaceName))]
                    )
                }
            }
            .accessibilityHidden(true)
    }

    private func selectionGesture(scrollProxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(viewportCoordinateSpaceName))
            .onChanged { value in
                guard let tokenID = geometryIndex.tokenID(nearest: value.location) else { return }
                if !isDraggingSelection {
                    isDraggingSelection = true
                    selectionAnchorTokenID = tokenID
                    selectionEndTokenID = tokenID
                    WKInterfaceDevice.current().play(.click)
                } else if selectionEndTokenID != tokenID {
                    selectionEndTokenID = tokenID
                }
                updateAutoScroll(at: value.location.y, scrollProxy: scrollProxy)
            }
            .onEnded { _ in
                isDraggingSelection = false
                stopAutoScroll()
            }
    }

    private func updateAutoScroll(at locationY: CGFloat, scrollProxy: ScrollViewProxy) {
        guard viewportHeight > 0 else {
            stopAutoScroll()
            return
        }

        let edgeState = WatchTextSelectionAutoScrollPolicy.edgeState(
            locationY: locationY,
            viewportHeight: viewportHeight
        )
        let nextDirection = edgeState?.direction
        let nextStrength = edgeState?.strength ?? 0

        if autoScrollDirection == nextDirection {
            autoScrollStrength = nextStrength
            return
        }
        stopAutoScroll()
        guard let nextDirection else { return }

        autoScrollDirection = nextDirection
        autoScrollStrength = nextStrength
        WKInterfaceDevice.current().play(nextDirection == .up ? .directionUp : .directionDown)
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled,
                  isDraggingSelection,
                  autoScrollDirection == nextDirection {
                let delay: UInt64 = autoScrollStrength > 0.65 ? 70_000_000 : 115_000_000
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { break }
                guard advanceSelection(nextDirection, scrollProxy: scrollProxy) else { break }
            }
        }
    }

    @discardableResult
    private func advanceSelection(
        _ direction: WatchTextSelectionAutoScrollDirection,
        scrollProxy: ScrollViewProxy
    ) -> Bool {
        guard let content, !content.tokens.isEmpty, let selectionEndTokenID else { return false }
        guard let targetTokenID = WatchTextSelectionAutoScrollPolicy.targetTokenID(
            currentTokenID: selectionEndTokenID,
            direction: direction,
            strength: autoScrollStrength,
            tokenCount: content.tokens.count
        ) else { return false }

        self.selectionEndTokenID = targetTokenID
        if reduceMotion {
            scrollProxy.scrollTo(targetTokenID, anchor: direction.anchor)
        } else {
            withAnimation(.linear(duration: 0.1)) {
                scrollProxy.scrollTo(targetTokenID, anchor: direction.anchor)
            }
        }
        return true
    }

    private func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        autoScrollDirection = nil
        autoScrollStrength = 0
    }

    private var selectedTokenRange: ClosedRange<Int>? {
        guard let anchor = selectionAnchorTokenID, let end = selectionEndTokenID else {
            return nil
        }
        return min(anchor, end)...max(anchor, end)
    }

    private func commitSelection() {
        guard let content, let selectedTokenRange else { return }
        let firstToken = content.tokens[selectedTokenRange.lowerBound]
        let lastToken = content.tokens[selectedTokenRange.upperBound]
        let selectedText = MessageTextSelectionSupport.substring(
            in: content.plainText,
            characterRange: firstToken.lowerCharacterOffset..<lastToken.upperCharacterOffset
        )
        commit(selectedText)
    }

    private func commit(_ text: String) {
        guard !text.isEmpty else { return }
        WKInterfaceDevice.current().play(.success)
        onCommit(text)
    }
}

enum WatchTextSelectionAutoScrollDirection: Equatable {
    case up
    case down

    var step: Int {
        self == .up ? -1 : 1
    }

    var anchor: UnitPoint {
        self == .up ? .top : .bottom
    }
}

struct WatchTextSelectionAutoScrollEdgeState: Equatable {
    let direction: WatchTextSelectionAutoScrollDirection
    let strength: CGFloat
}

enum WatchTextSelectionAutoScrollPolicy {
    static func edgeState(
        locationY: CGFloat,
        viewportHeight: CGFloat
    ) -> WatchTextSelectionAutoScrollEdgeState? {
        guard viewportHeight > 0 else { return nil }
        let edgeInset = min(max(viewportHeight * 0.2, 28), 44)
        if locationY < edgeInset {
            return WatchTextSelectionAutoScrollEdgeState(
                direction: .up,
                strength: min(max((edgeInset - locationY) / edgeInset, 0), 1)
            )
        }
        if locationY > viewportHeight - edgeInset {
            return WatchTextSelectionAutoScrollEdgeState(
                direction: .down,
                strength: min(max((locationY - (viewportHeight - edgeInset)) / edgeInset, 0), 1)
            )
        }
        return nil
    }

    static func targetTokenID(
        currentTokenID: Int,
        direction: WatchTextSelectionAutoScrollDirection,
        strength: CGFloat,
        tokenCount: Int
    ) -> Int? {
        guard tokenCount > 0 else { return nil }
        let tokenStride = strength > 0.65 ? 2 : 1
        let target = min(
            max(currentTokenID + direction.step * tokenStride, 0),
            tokenCount - 1
        )
        return target == currentTokenID ? nil : target
    }
}

private struct WatchSelectableMessageContent: Sendable {
    let plainText: String
    let tokens: [WatchSelectableMessageToken]
    let paragraphTokenRanges: [Range<Int>]

    nonisolated static func prepare(markdown: String) -> Self {
        let plainText = MessageTextSelectionSupport.plainText(fromMarkdown: markdown)
        var tokens: [WatchSelectableMessageToken] = []
        var paragraphTokenRanges: [Range<Int>] = []
        var paragraphStart = 0
        var currentText = ""
        var currentStart = 0
        var currentKind: WatchSelectableMessageTokenKind?
        var characterOffset = 0

        func appendedCurrentToken() -> WatchSelectableMessageToken? {
            guard !currentText.isEmpty else { return nil }
            return WatchSelectableMessageToken(
                id: tokens.count,
                text: currentText,
                lowerCharacterOffset: currentStart,
                upperCharacterOffset: characterOffset
            )
        }

        for character in plainText {
            if character == "\n" {
                if let token = appendedCurrentToken() {
                    tokens.append(token)
                }
                currentText = ""
                currentKind = nil
                paragraphTokenRanges.append(paragraphStart..<tokens.count)
                paragraphStart = tokens.count
                characterOffset += 1
                continue
            }

            if character.isWhitespace {
                if currentText.isEmpty {
                    currentStart = characterOffset
                }
                currentText.append(character)
                currentKind = .whitespace
                characterOffset += 1
                continue
            }

            let kind = WatchSelectableMessageTokenKind(character: character)
            if !currentText.isEmpty, currentKind != kind || kind == .individual {
                if let token = appendedCurrentToken() {
                    tokens.append(token)
                }
                currentText = ""
            }

            if currentText.isEmpty {
                currentStart = characterOffset
                currentKind = kind
            }
            currentText.append(character)
            characterOffset += 1
        }

        if let token = appendedCurrentToken() {
            tokens.append(token)
        }
        paragraphTokenRanges.append(paragraphStart..<tokens.count)

        return Self(
            plainText: plainText,
            tokens: tokens,
            paragraphTokenRanges: paragraphTokenRanges
        )
    }
}

private struct WatchSelectableMessageToken: Identifiable, Sendable {
    let id: Int
    let text: String
    let lowerCharacterOffset: Int
    let upperCharacterOffset: Int
}

nonisolated private enum WatchSelectableMessageTokenKind: Equatable {
    case asciiWord
    case whitespace
    case individual

    nonisolated init(character: Character) {
        let isASCIIWord = character.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
        }
        self = isASCIIWord ? .asciiWord : .individual
    }
}

private struct WatchSelectableTextFlowLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(subviews: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(subviews: subviews, width: bounds.width)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    private func layout(subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        points.reserveCapacity(subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight
                x = 0
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x)
        }

        return (points, CGSize(width: min(usedWidth, width), height: y + lineHeight))
    }
}

private struct WatchTextSelectionTokenFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct WatchTextSelectionViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WatchTextSelectionGeometryIndex: Equatable {
    struct Item: Equatable {
        let tokenID: Int
        let frame: CGRect
    }

    struct Row: Equatable {
        var minY: CGFloat
        var maxY: CGFloat
        var items: [Item]

        var midY: CGFloat { (minY + maxY) / 2 }
    }

    static let empty = Self(rows: [])
    let rows: [Row]

    init(frames: [Int: CGRect]) {
        let sortedItems = frames.map { Item(tokenID: $0.key, frame: $0.value) }
            .sorted {
                if abs($0.frame.midY - $1.frame.midY) < 1 {
                    return $0.frame.minX < $1.frame.minX
                }
                return $0.frame.midY < $1.frame.midY
            }
        var rows: [Row] = []

        for item in sortedItems {
            if var last = rows.last,
               item.frame.minY <= last.maxY,
               item.frame.maxY >= last.minY {
                last.minY = min(last.minY, item.frame.minY)
                last.maxY = max(last.maxY, item.frame.maxY)
                last.items.append(item)
                last.items.sort { $0.frame.midX < $1.frame.midX }
                rows[rows.count - 1] = last
            } else {
                rows.append(Row(minY: item.frame.minY, maxY: item.frame.maxY, items: [item]))
            }
        }
        self.rows = rows
    }

    private init(rows: [Row]) {
        self.rows = rows
    }

    func tokenID(nearest point: CGPoint) -> Int? {
        guard !rows.isEmpty else { return nil }
        let row = rows[nearestRowIndex(to: point.y)]
        let itemIndex = nearestItemIndex(to: point.x, in: row.items)
        return row.items[itemIndex].tokenID
    }

    private func nearestRowIndex(to value: CGFloat) -> Int {
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rows[middle].midY < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        if lower == 0 { return 0 }
        if lower == rows.count { return rows.count - 1 }
        return abs(rows[lower].midY - value) < abs(rows[lower - 1].midY - value) ? lower : lower - 1
    }

    private func nearestItemIndex(to value: CGFloat, in items: [Item]) -> Int {
        var lower = 0
        var upper = items.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if items[middle].frame.midX < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        if lower == 0 { return 0 }
        if lower == items.count { return items.count - 1 }
        return abs(items[lower].frame.midX - value) < abs(items[lower - 1].frame.midX - value) ? lower : lower - 1
    }
}
