// ============================================================================
// ConversationContinuationToolViews.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责续聊上下文的结构化内容分段与工具结果二级折叠。
// ============================================================================

import SwiftUI
import ETOSCore

struct ConversationContinuationTextPreview: Sendable {
    let full: String
    let displayed: String
    let characterCount: Int
    let isTruncated: Bool

    nonisolated init(text: String, limit: Int) {
        let characterCount = text.count
        self.full = text
        self.displayed = characterCount > limit
            ? String(text.prefix(limit))
            : text
        self.characterCount = characterCount
        self.isTruncated = characterCount > limit
    }
}

struct ConversationContinuationToolContent: Identifiable, Sendable {
    let tool: ConversationContinuationRetainedTool
    let arguments: ConversationContinuationTextPreview
    let result: ConversationContinuationTextPreview

    var id: String { tool.id }

    nonisolated init(tool: ConversationContinuationRetainedTool) {
        self.tool = tool
        self.arguments = ConversationContinuationTextPreview(
            text: tool.arguments,
            limit: ToolCallTextPreviewConstants.previewLimit
        )
        self.result = ConversationContinuationTextPreview(
            text: tool.result,
            limit: ToolCallTextPreviewConstants.previewLimit
        )
    }
}

enum ConversationContinuationContentSegment: Identifiable, Sendable {
    case markdown(id: String, content: String)
    case tool(ConversationContinuationToolContent)

    var id: String {
        switch self {
        case .markdown(let id, _):
            return id
        case .tool(let tool):
            return tool.id
        }
    }
}

struct ConversationContinuationDisplayContent: Sendable {
    nonisolated static let previewCharacterLimit = 5_000
    private nonisolated static let toolPreviewCharacterCost = 32

    let full: [ConversationContinuationContentSegment]
    let preview: [ConversationContinuationContentSegment]
    let isPreviewTruncated: Bool

    nonisolated static func make(
        context: ConversationContinuationContext,
        summaryHeading: String,
        retainedHeading: String,
        roleTitles: [String: String]
    ) -> ConversationContinuationDisplayContent {
        let retainedItems = ConversationContinuationRetainedContentPlanner.makeItems(
            from: context.retainedMessages
        )
        var fullSegments: [ConversationContinuationContentSegment] = []
        var pendingMarkdown = ["## \(summaryHeading)\n\n\(context.summary)"]
        var markdownIndex = 0

        func flushMarkdown() {
            guard !pendingMarkdown.isEmpty else { return }
            fullSegments.append(.markdown(
                id: "markdown:\(markdownIndex)",
                content: pendingMarkdown.joined(separator: "\n\n")
            ))
            markdownIndex += 1
            pendingMarkdown.removeAll(keepingCapacity: true)
        }

        if !context.retainedMessages.isEmpty {
            pendingMarkdown.append("## \(retainedHeading)")
            for item in retainedItems {
                switch item {
                case .message(let message):
                    let roleTitle = roleTitles[message.role.rawValue] ?? message.role.rawValue
                    pendingMarkdown.append("### \(roleTitle)\n\n\(message.content)")
                case .tool(let tool):
                    flushMarkdown()
                    fullSegments.append(.tool(ConversationContinuationToolContent(tool: tool)))
                }
            }
        }
        flushMarkdown()

        let previewResult = makePreview(from: fullSegments)
        return ConversationContinuationDisplayContent(
            full: fullSegments,
            preview: previewResult.segments,
            isPreviewTruncated: previewResult.isTruncated
        )
    }

    private nonisolated static func makePreview(
        from full: [ConversationContinuationContentSegment]
    ) -> (segments: [ConversationContinuationContentSegment], isTruncated: Bool) {
        var remaining = previewCharacterLimit
        var preview: [ConversationContinuationContentSegment] = []

        for segment in full {
            switch segment {
            case .markdown(let id, let content):
                if content.count <= remaining {
                    preview.append(segment)
                    remaining -= content.count
                } else {
                    let displayed = String(content.prefix(max(0, remaining))) + "\n\n…"
                    preview.append(.markdown(id: id, content: displayed))
                    return (preview, true)
                }
            case .tool(let tool):
                let cost = toolPreviewCharacterCost + (tool.tool.toolName?.count ?? 0)
                guard cost <= remaining else { return (preview, true) }
                preview.append(segment)
                remaining -= cost
            }
        }
        return (preview, false)
    }
}

struct ConversationContinuationToolDisclosure: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let content: ConversationContinuationToolContent
    @Binding var isExpanded: Bool
    let primaryTextColor: Color
    let secondaryTextColor: Color

    var body: some View {
        VStack(alignment: .leading) {
            Button(action: toggleExpansion) {
                HStack {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading) {
                        Text(toolDisplayLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(primaryTextColor)
                        Text(statusTitle)
                            .font(.caption)
                            .foregroundStyle(secondaryTextColor)
                    }

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(secondaryTextColor)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading) {
                    if !content.arguments.full.isEmpty {
                        Text(NSLocalizedString("参数", comment: "Tool arguments section title"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(secondaryTextColor)
                        ToolCallLongTextPreview(
                            title: NSLocalizedString("参数", comment: "Tool arguments section title"),
                            text: content.arguments.full,
                            usesMonospacedFont: true,
                            displayedText: content.arguments.displayed,
                            textCharacterCount: content.arguments.characterCount,
                            needsExpansion: content.arguments.isTruncated,
                            customTextColor: secondaryTextColor
                        )
                    }

                    if !content.result.full.isEmpty {
                        Text(NSLocalizedString("工具结果", comment: "Tool result section title"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(secondaryTextColor)
                        ToolCallLongTextPreview(
                            title: NSLocalizedString("工具结果", comment: "Tool result section title"),
                            text: content.result.full,
                            usesMonospacedFont: true,
                            displayedText: content.result.displayed,
                            textCharacterCount: content.result.characterCount,
                            needsExpansion: content.result.isTruncated,
                            customTextColor: secondaryTextColor
                        )
                    }
                }
                .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var toolDisplayLabel: String {
        guard let toolName = content.tool.toolName, !toolName.isEmpty else {
            return NSLocalizedString("工具结果", comment: "Standalone continuation tool result title")
        }
        if toolName == "save_memory" {
            return NSLocalizedString("添加记忆", comment: "Tool label for saving memory.")
        }
        if let label = MCPManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = ShortcutToolManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = SkillManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = AppToolManager.shared.displayLabel(for: toolName) {
            return label
        }
        return toolName
    }

    private var statusTitle: String {
        content.result.full.isEmpty
            ? NSLocalizedString("工具调用", comment: "Continuation tool call without a stored result")
            : NSLocalizedString("已完成", comment: "Completed continuation tool call")
    }

    private func toggleExpansion() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
                isExpanded.toggle()
            }
        }
    }
}
