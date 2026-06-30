// ============================================================================
// ChatBubbleToolDetailSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳聊天气泡中的工具详情面板与详情文本处理逻辑。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

enum ToolCallTextPreviewConstants {
    static let previewLimit = 3_000
}

func formattedToolCallJSONOrRaw(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "{}" }

    // 超长参数直接使用原文预览，避免在打开详情前同步解析和重排大块 JSON。
    guard trimmed.count <= ToolCallTextPreviewConstants.previewLimit else {
        return trimmed
    }

    guard let data = trimmed.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          JSONSerialization.isValidJSONObject(object),
          let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let prettyText = String(data: prettyData, encoding: .utf8) else {
        return trimmed
    }
    return prettyText
}

extension ChatBubble {
    struct ToolCallDetailSheetItem: Identifiable, Equatable {
        let messageID: UUID
        let toolCallID: String
        let fallbackToolCall: InternalToolCall

        var id: String {
            "\(messageID.uuidString)-\(toolCallID)"
        }
    }

    @ViewBuilder
    func toolCallDetailSheet(for item: ToolCallDetailSheetItem) -> some View {
        let call = resolvedToolCall(for: item)
        let displayName = toolDisplayLabel(for: call.toolName)
        let status = toolCallStatus(for: call)
        let argumentText = formattedToolCallJSONOrRaw(call.arguments)
        let resultText = resolvedToolResultText(for: call)
        let permissionRequest = activeToolPermissionRequest(for: call)
        let argumentSectionTitle = NSLocalizedString("工具参数", comment: "Tool detail arguments section title")

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    toolDetailTopBar(
                        displayName: displayName,
                        status: status,
                        permissionRequest: permissionRequest
                    )

                    toolDetailSection(title: argumentSectionTitle) {
                        ToolCallLongTextPreview(
                            title: argumentSectionTitle,
                            text: argumentText,
                            usesMonospacedFont: true
                        )
                    }

                    if permissionRequest == nil {
                        toolDetailSection(title: NSLocalizedString("工具结果", comment: "Tool detail result section title")) {
                            toolResultSheetContent(
                                status: status,
                                resultText: resultText
                            )
                        }
                    }

                    if let permissionRequest {
                        toolApprovalSection(for: permissionRequest)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color.clear)
        }
    }

    private func toolDetailTopBar(
        displayName: String,
        status: ToolCallBubbleStatus,
        permissionRequest: ToolPermissionRequest?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Spacer(minLength: 6)
                Button(NSLocalizedString("关闭", comment: "")) {
                    selectedToolCallDetailSheetItem = nil
                }
                .etFont(.footnote)
                .buttonStyle(.bordered)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(status.accentColor)
                    .etFont(.system(size: 15, weight: .semibold))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("调用工具", comment: ""))
                        .etFont(.headline)
                    Text(displayName)
                        .etFont(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(status.title)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                    if permissionRequest != nil {
                        Text(NSLocalizedString("等待你的审批后继续执行。", comment: ""))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let permissionRequest,
                       let countdownText = toolPermissionCountdownText(for: permissionRequest) {
                        Label(countdownText, systemImage: "timer")
                            .etFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func toolApprovalSection(for permissionRequest: ToolPermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("审批操作", comment: ""))
                .etFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ToolPermissionInlineView(
                request: permissionRequest,
                onDecision: { decision in
                    toolPermissionCenter.resolveActiveRequest(with: decision)
                    selectedToolCallDetailSheetItem = nil
                }
            )
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    func toolDetailSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString(title, comment: "工具详情小节标题"))
                .etFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    @ViewBuilder
    private func toolResultSheetContent(
        status: ToolCallBubbleStatus,
        resultText: String
    ) -> some View {
        if resultText.isEmpty {
            Text(status == .pendingApproval ? NSLocalizedString("等待你的审批后继续执行。", comment: "") : NSLocalizedString("暂无返回结果。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        } else if resultText.count > ToolCallTextPreviewConstants.previewLimit {
            ToolCallLongTextPreview(
                title: NSLocalizedString("工具结果", comment: "Tool detail result section title"),
                text: resultText,
                usesMonospacedFont: true
            )
        } else if enableExperimentalToolResultDisplay {
            let displayModel = MCPToolResultFormatter.displayModel(from: resultText)
            let primaryContent = displayModel.primaryContentText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasPrimaryContent = !(primaryContent ?? "").isEmpty
            let canToggleRaw = hasPrimaryContent && displayModel.shouldShowRawSection
            let showRaw = canToggleRaw && showRawToolResultInDetailSheet

            VStack(alignment: .leading, spacing: 8) {
                if showRaw || !hasPrimaryContent {
                    ToolCallLongTextPreview(
                        title: NSLocalizedString("工具结果", comment: "Tool detail result section title"),
                        text: displayModel.rawDisplayText,
                        usesMonospacedFont: true
                    )
                } else if let primaryContent {
                    ToolCallLongTextPreview(
                        title: NSLocalizedString("工具结果", comment: "Tool detail result section title"),
                        text: primaryContent,
                        usesMonospacedFont: false
                    )
                }

                if canToggleRaw {
                    Button(showRawToolResultInDetailSheet ? NSLocalizedString("显示整理结果", comment: "") : NSLocalizedString("显示原文", comment: "")) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showRawToolResultInDetailSheet.toggle()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else {
            ToolCallLongTextPreview(
                title: NSLocalizedString("工具结果", comment: "Tool detail result section title"),
                text: resultText,
                usesMonospacedFont: true
            )
        }
    }

    private func toolPermissionCountdownText(for request: ToolPermissionRequest) -> String? {
        guard let remaining = toolPermissionCenter.autoApproveRemainingSeconds(for: request) else {
            return nil
        }
        return String(format: NSLocalizedString("将在 %ds 后自动允许", comment: ""), remaining)
    }

    enum ToolCallBubbleStatus: Equatable {
        case pendingApproval
        case running
        case finished
        case rejected

        var title: String {
            switch self {
            case .pendingApproval:
                return NSLocalizedString("等待审批", comment: "")
            case .running:
                return NSLocalizedString("执行中", comment: "")
            case .finished:
                return NSLocalizedString("已完成", comment: "")
            case .rejected:
                return NSLocalizedString("已拒绝", comment: "")
            }
        }

        var iconName: String {
            switch self {
            case .pendingApproval:
                return "hourglass"
            case .running:
                return "clock.arrow.trianglehead.counterclockwise.rotate.90"
            case .finished:
                return "checkmark.circle.fill"
            case .rejected:
                return "xmark.circle.fill"
            }
        }

        var accentColor: Color {
            switch self {
            case .pendingApproval:
                return .orange
            case .running:
                return .blue
            case .finished:
                return .green
            case .rejected:
                return .red
            }
        }
    }
}

struct ToolCallLongTextPreview: View {
    let title: String
    let text: String
    let usesMonospacedFont: Bool
    let displayedText: String
    let textCharacterCount: Int
    let needsExpansion: Bool

    init(
        title: String,
        text: String,
        usesMonospacedFont: Bool
    ) {
        self.title = title
        self.text = text
        self.usesMonospacedFont = usesMonospacedFont
        let characterCount = text.count
        let expands = characterCount > ToolCallTextPreviewConstants.previewLimit
        self.textCharacterCount = characterCount
        self.needsExpansion = expands
        self.displayedText = expands ? String(text.prefix(ToolCallTextPreviewConstants.previewLimit)) : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            previewText

            if needsExpansion {
                Text(String(format: NSLocalizedString("已显示前 %d 个字符，共 %d 个字符。", comment: ""), ToolCallTextPreviewConstants.previewLimit, textCharacterCount))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    ToolCallPagedTextView(title: title, text: text)
                } label: {
                    Text(NSLocalizedString("显示完整内容", comment: ""))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var previewText: some View {
        if usesMonospacedFont {
            Text(displayedText)
                .etFont(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(displayedText)
                .etFont(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ToolCallPagedTextView: View {
    let title: String
    let pages: [AppLogTextPage]
    let textCharacterCount: Int

    @State private var selectedPageIndex = 0

    init(title: String, text: String) {
        self.title = title
        self.pages = AppLogTextPaginator.paginate(text, pageSize: ToolCallTextPreviewConstants.previewLimit)
        self.textCharacterCount = text.count
    }

    private var currentPage: AppLogTextPage {
        let clampedIndex = min(max(selectedPageIndex, 0), pages.count - 1)
        return pages[clampedIndex]
    }

    private var hasMultiplePages: Bool {
        pages.count > 1
    }

    private var canGoToPreviousPage: Bool {
        selectedPageIndex > 0
    }

    private var canGoToNextPage: Bool {
        selectedPageIndex + 1 < pages.count
    }

    private var paginationSummaryText: String {
        String(format: NSLocalizedString("当前显示%d-%d条结果(总共%d)", comment: ""), currentPage.startCharacterNumber, currentPage.endCharacterNumber, textCharacterCount)
    }

    var body: some View {
        List {
            Section {
                Text(currentPage.content)
                    .etFont(.footnote.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text(String(format: NSLocalizedString("第 %d / %d 页", comment: ""), currentPage.index + 1, currentPage.totalCount))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if hasMultiplePages {
                paginationBar
            }
        }
    }

    private var paginationBar: some View {
        HStack(spacing: 12) {
            Button {
                goToPreviousPage()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.bordered)
            .disabled(!canGoToPreviousPage)
            .accessibilityLabel(NSLocalizedString("上一页", comment: ""))

            Text(paginationSummaryText)
                .etFont(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button {
                goToNextPage()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.bordered)
            .disabled(!canGoToNextPage)
            .accessibilityLabel(NSLocalizedString("下一页", comment: ""))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func goToPreviousPage() {
        guard canGoToPreviousPage else { return }
        selectedPageIndex -= 1
    }

    private func goToNextPage() {
        guard canGoToNextPage else { return }
        selectedPageIndex += 1
    }
}
