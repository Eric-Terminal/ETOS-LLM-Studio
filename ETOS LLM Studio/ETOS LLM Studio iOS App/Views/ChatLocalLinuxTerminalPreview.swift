// ============================================================================
// ChatLocalLinuxTerminalPreview.swift
// ============================================================================
// ETOS LLM Studio
//
// 聊天页按设置缩略显示当前会话的 Agent 工具或既有用户终端；预览本身
// 不启动 Linux、不创建新 PTY，也不替代工具详情与用户接管入口。
// ============================================================================

import ETOSCore
import SwiftUI
import UIKit
import WebKit

struct LocalLinuxChatFloatingPreview: View {
    let mode: LocalLinuxChatPreviewMode
    let isLocalLinuxEnabled: Bool
    let agentToolPreview: AgentToolExecutionPreviewSnapshot?
    let sessionID: UUID?
    let containerSize: CGSize
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    @Binding var offset: CGSize
    let isLiquidGlassEnabled: Bool
    let onOpenTerminal: (UUID) -> Void
    let onOpenBrowser: () -> Void

    @State private var isCollapsed = false

    @ViewBuilder
    var body: some View {
        switch mode {
        case .off:
            EmptyView()
        case .agentTools:
            AgentToolExecutionFloatingPreview(
                preview: agentToolPreview,
                sessionID: sessionID,
                containerSize: containerSize,
                topPadding: topPadding,
                bottomPadding: bottomPadding,
                offset: $offset,
                isCollapsed: $isCollapsed,
                isLiquidGlassEnabled: isLiquidGlassEnabled,
                onOpenBrowser: onOpenBrowser
            )
        case .userTerminal:
            LocalLinuxTerminalFloatingPreview(
                isEnabled: isLocalLinuxEnabled,
                containerSize: containerSize,
                topPadding: topPadding,
                bottomPadding: bottomPadding,
                offset: $offset,
                isCollapsed: $isCollapsed,
                isLiquidGlassEnabled: isLiquidGlassEnabled,
                onOpen: onOpenTerminal
            )
        }
    }
}

struct LocalLinuxChatDockedPreview: View {
    let mode: LocalLinuxChatPreviewMode
    let isLocalLinuxEnabled: Bool
    let agentToolPreview: AgentToolExecutionPreviewSnapshot?
    let isLiquidGlassEnabled: Bool
    let onOpenTerminal: (UUID) -> Void
    let onOpenBrowser: () -> Void

    @ViewBuilder
    var body: some View {
        switch mode {
        case .off:
            EmptyView()
        case .agentTools:
            AgentToolExecutionDockedPreview(
                preview: agentToolPreview,
                isLiquidGlassEnabled: isLiquidGlassEnabled,
                onOpenBrowser: onOpenBrowser
            )
        case .userTerminal:
            LocalLinuxTerminalDockedPreview(
                isEnabled: isLocalLinuxEnabled,
                isLiquidGlassEnabled: isLiquidGlassEnabled,
                onOpen: onOpenTerminal
            )
        }
    }
}

private struct AgentToolExecutionDockedPreview: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let preview: AgentToolExecutionPreviewSnapshot?
    let isLiquidGlassEnabled: Bool
    let onOpenBrowser: () -> Void

    @State private var isShowingDetail = false

    var body: some View {
        Group {
            if let preview {
                Button {
                    isShowingDetail = true
                } label: {
                    HStack {
                        Image(systemName: AgentToolPreviewMetadata.iconName(for: preview.toolName))
                            .etFont(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TelegramColors.attachButtonColor)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(preview.displayTitle ?? AgentToolPreviewMetadata.displayName(for: preview.toolName))
                                .etFont(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(preview.previewText.isEmpty
                                 ? NSLocalizedString("等待工具输出…", comment: "Agent tool preview waiting placeholder")
                                 : preview.previewText)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: preview.state == .running ? "clock" : "checkmark.circle.fill")
                            .etFont(.system(size: 11, weight: .semibold))
                            .foregroundStyle(preview.state == .running ? Color.orange : Color.green)

                        Image(systemName: "chevron.right")
                            .etFont(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(LocalLinuxDockedPreviewBackground(isLiquidGlassEnabled: isLiquidGlassEnabled))
                .accessibilityLabel(NSLocalizedString("展开 Agent 工具预览", comment: "Expand Agent tool execution preview"))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .sheet(isPresented: $isShowingDetail) {
                    AgentToolExecutionPreviewDetail(
                        preview: preview,
                        displayName: AgentToolPreviewMetadata.displayName(for: preview.toolName),
                        iconName: AgentToolPreviewMetadata.iconName(for: preview.toolName),
                        browserImage: nil,
                        onOpenBrowser: AgentToolPreviewMetadata.isBrowserTool(preview.toolName) ? onOpenBrowser : nil
                    )
                }
            }
        }
        .animation(
            accessibilityReduceMotion ? nil : .spring(response: 0.32, dampingFraction: 1),
            value: preview?.id
        )
    }
}

private struct LocalLinuxTerminalDockedPreview: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var terminalPreview = LocalLinuxTerminalPreviewModel()

    let isEnabled: Bool
    let isLiquidGlassEnabled: Bool
    let onOpen: (UUID) -> Void

    var body: some View {
        Group {
            if let activeTerminalID = terminalPreview.activeTerminalID {
                Button {
                    onOpen(activeTerminalID)
                } label: {
                    HStack {
                        Image(systemName: "terminal.fill")
                            .etFont(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TelegramColors.attachButtonColor)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(NSLocalizedString("用户终端", comment: "User terminal preview title"))
                                    .etFont(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.primary)

                                if terminalPreview.activeTerminalCount > 1 {
                                    Label("\(terminalPreview.activeTerminalCount)", systemImage: "rectangle.stack")
                                        .labelStyle(.titleAndIcon)
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Group {
                                if terminalPreview.presentation.plainText.isEmpty {
                                    Text(NSLocalizedString("终端正在启动…", comment: "Linux terminal starting placeholder"))
                                } else {
                                    Text(terminalPreview.presentation.attributedText)
                                }
                            }
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .etFont(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(LocalLinuxDockedPreviewBackground(isLiquidGlassEnabled: isLiquidGlassEnabled))
                .accessibilityLabel(NSLocalizedString("打开用户终端", comment: "Open user Linux terminal"))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(
            accessibilityReduceMotion ? nil : .spring(response: 0.32, dampingFraction: 1),
            value: terminalPreview.activeTerminalID
        )
        .task(id: isEnabled) {
            await terminalPreview.observeActivity(isEnabled: isEnabled)
        }
        .task(id: terminalOutputObservationID) {
            await terminalPreview.observeOutput(appearance: terminalAppearance, maximumLines: 2)
        }
    }

    private var terminalAppearance: LocalLinuxTerminalAppearance {
        colorScheme == .dark ? .dark : .light
    }

    private var terminalOutputObservationID: String {
        "\(terminalPreview.activeTerminalID?.uuidString ?? "none")|\(terminalAppearance)"
    }
}

private struct LocalLinuxDockedPreviewBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appConfig = AppConfigStore.shared

    let isLiquidGlassEnabled: Bool

    var body: some View {
        // 停靠预览与消息输入框属于同一底部操作区，沿用同一套材质参数，
        // 避免壁纸透过时出现两层透明度不同的“拼接感”。
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    shape
                        .fill(Color.clear)
                        .glassEffect(.clear, in: shape)
                        .overlay(shape.fill(overlayColor))
                        .overlay(shape.stroke(strokeColor, lineWidth: 0.5))
                        .shadow(color: shadowColor, radius: 6, x: 0, y: 2)
                } else {
                    materialBackground(shape: shape)
                }
            } else {
                materialBackground(shape: shape)
            }
        }
    }

    private func materialBackground(shape: RoundedRectangle) -> some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(overlayColor))
            .overlay(shape.stroke(strokeColor, lineWidth: 0.5))
            .shadow(color: shadowColor, radius: 6, x: 0, y: 2)
    }

    private var overlayColor: Color {
        let opacity = LiquidGlassTintSetting.normalized(appConfig.liquidGlassTintOpacity)
        return colorScheme == .dark ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
    }

    private var strokeColor: Color {
        Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28)
    }

    private var shadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1)
    }
}

private enum AgentToolPreviewMetadata {
    static func displayName(for toolName: String) -> String {
        if isBrowserTool(toolName) {
            return NSLocalizedString("浏览器", comment: "Browser Agent tool preview title")
        }
        if isLinuxTool(toolName) {
            return NSLocalizedString("Linux", comment: "Linux Agent tool preview title")
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

    static func iconName(for toolName: String) -> String {
        if isBrowserTool(toolName) { return "safari" }
        if isLinuxTool(toolName) { return "terminal" }
        if toolName.localizedCaseInsensitiveContains("file") { return "doc.text" }
        return "wrench.and.screwdriver"
    }

    static func isBrowserTool(_ toolName: String) -> Bool {
        toolName == "browser_control" || toolName.hasSuffix("/browser_control")
    }

    static func isLinuxTool(_ toolName: String) -> Bool {
        ["linux_run", "linux_shell", "linux_process"].contains { candidate in
            toolName == candidate || toolName.hasSuffix("/\(candidate)") || toolName.hasSuffix("_\(candidate)")
        }
    }
}

struct AgentToolExecutionFloatingPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var browserManager = BrowserSessionManager.shared

    let preview: AgentToolExecutionPreviewSnapshot?
    let sessionID: UUID?
    let containerSize: CGSize
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    @Binding var offset: CGSize
    @Binding var isCollapsed: Bool
    let isLiquidGlassEnabled: Bool
    let onOpenBrowser: () -> Void

    @State private var browserImage: UIImage?
    @State private var dragStartOffset: CGSize?
    @State private var isShowingDetail = false

    private let expandedPanelSize = CGSize(width: 168, height: 112)
    private let collapsedPanelSize = CGSize(width: 44, height: 44)

    private var panelSize: CGSize {
        isCollapsed ? collapsedPanelSize : expandedPanelSize
    }

    var body: some View {
        Group {
            if let preview {
                Group {
                    if isCollapsed {
                        collapsedPanelContent(preview)
                            .transition(.opacity.combined(with: .scale(scale: 0.82)))
                            .gesture(
                                dragGesture.exclusively(
                                    before: TapGesture().onEnded { setCollapsed(false) }
                                )
                            )
                    } else {
                        panelContent(preview)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .position(
                    x: defaultCenter.x + clampedOffset.width,
                    y: defaultCenter.y + clampedOffset.height
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 1), value: isCollapsed)
        .task(id: browserSnapshotObservationID) {
            await observeBrowserSnapshot()
        }
        .sheet(isPresented: $isShowingDetail) {
            if let preview {
                AgentToolExecutionPreviewDetail(
                    preview: preview,
                    displayName: displayName(for: preview.toolName),
                    iconName: iconName(for: preview.toolName),
                    browserImage: browserImage,
                    onOpenBrowser: isBrowserTool(preview.toolName) ? onOpenBrowser : nil
                )
            }
        }
    }

    private func collapsedPanelContent(_ preview: AgentToolExecutionPreviewSnapshot) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: iconName(for: preview.toolName))
                .etFont(.system(size: 17, weight: .semibold))
                .foregroundStyle(TelegramColors.attachButtonColor)

            Circle()
                .fill(preview.state == .running ? Color.orange : Color.green)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                .offset(x: 2, y: 2)
        }
        .frame(width: collapsedPanelSize.width, height: collapsedPanelSize.height)
        .background(panelBackground(cornerRadius: collapsedPanelSize.width / 2))
        .clipShape(Circle())
        .contentShape(Circle())
        .accessibilityLabel(NSLocalizedString("展开 Agent 工具预览", comment: "Expand Agent tool execution preview"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { setCollapsed(false) }
    }

    private func panelContent(_ preview: AgentToolExecutionPreviewSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: preview.toolName))
                        .etFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TelegramColors.attachButtonColor)

                    Text(preview.displayTitle ?? displayName(for: preview.toolName))
                        .etFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Label(preview.state == .running
                          ? NSLocalizedString("执行中", comment: "Agent tool preview running")
                          : NSLocalizedString("已完成", comment: "Agent tool preview completed"),
                          systemImage: preview.state == .running ? "clock" : "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .etFont(.system(size: 9, weight: .semibold))
                        .foregroundStyle(preview.state == .running ? Color.orange : Color.green)
                }
                .contentShape(Rectangle())
                .gesture(expandedInteractionGesture)

                Button {
                    setCollapsed(true)
                } label: {
                    Image(systemName: "minus")
                        .etFont(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("收起 Agent 工具预览", comment: "Collapse Agent tool execution preview"))
            }
            .padding(.horizontal, 9)
            .frame(height: 30)

            Group {
                if isBrowserTool(preview.toolName), let browserImage {
                    Image(uiImage: browserImage)
                        .resizable()
                        .scaledToFill()
                } else if preview.previewText.isEmpty {
                    Text(NSLocalizedString("等待工具输出…", comment: "Agent tool preview waiting placeholder"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(preview.previewText)
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(previewCanvasColor)
            .contentShape(Rectangle())
            .clipped()
            .gesture(expandedInteractionGesture)
            .accessibilityLabel(NSLocalizedString("展开 Agent 工具预览", comment: "Expand Agent tool execution preview"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isShowingDetail = true }
        }
        .frame(width: expandedPanelSize.width, height: expandedPanelSize.height)
        .background(panelBackground(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func observeBrowserSnapshot() async {
        guard let preview,
              isBrowserTool(preview.toolName),
              let sessionID else {
            browserImage = nil
            return
        }

        repeat {
            guard !Task.isCancelled else { return }
            if let webView = browserManager.selectedWebView(sessionID: sessionID) {
                let configuration = WKSnapshotConfiguration()
                configuration.snapshotWidth = NSNumber(value: expandedPanelSize.width * 2)
                browserImage = try? await webView.takeSnapshot(configuration: configuration)
            } else {
                browserImage = nil
            }

            guard preview.state == .running else { return }
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
        } while true
    }

    private func displayName(for toolName: String) -> String {
        AgentToolPreviewMetadata.displayName(for: toolName)
    }

    private func iconName(for toolName: String) -> String {
        AgentToolPreviewMetadata.iconName(for: toolName)
    }

    private func isBrowserTool(_ toolName: String) -> Bool {
        AgentToolPreviewMetadata.isBrowserTool(toolName)
    }

    private func isLinuxTool(_ toolName: String) -> Bool {
        AgentToolPreviewMetadata.isLinuxTool(toolName)
    }

    private var browserSnapshotObservationID: String {
        guard let preview else { return "none" }
        return "\(preview.id)#\(preview.state)#\(sessionID?.uuidString ?? "none")"
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if dragStartOffset == nil {
                    dragStartOffset = offset
                }
                let startOffset = dragStartOffset ?? offset
                offset = clamp(
                    CGSize(
                        width: startOffset.width + value.translation.width,
                        height: startOffset.height + value.translation.height
                    ),
                    panelSize: panelSize
                )
            }
            .onEnded { value in
                let startOffset = dragStartOffset ?? offset
                offset = clamp(
                    CGSize(
                        width: startOffset.width + value.translation.width,
                        height: startOffset.height + value.translation.height
                    ),
                    panelSize: panelSize
                )
                dragStartOffset = nil
            }
    }

    private var expandedInteractionGesture: some Gesture {
        dragGesture.exclusively(
            before: TapGesture().onEnded { isShowingDetail = true }
        )
    }

    private var clampedOffset: CGSize {
        clamp(offset, panelSize: panelSize)
    }

    private func setCollapsed(_ collapsed: Bool) {
        let targetSize = collapsed ? collapsedPanelSize : expandedPanelSize
        withAnimation(.spring(response: 0.32, dampingFraction: 1)) {
            isCollapsed = collapsed
            offset = clamp(offset, panelSize: targetSize)
        }
    }

    private func clamp(_ candidate: CGSize, panelSize: CGSize) -> CGSize {
        let minX = panelSize.width / 2 + 12
        let maxX = max(minX, containerSize.width - panelSize.width / 2 - 12)
        let minY = topPadding + panelSize.height / 2
        let maxY = max(minY, containerSize.height - bottomPadding - panelSize.height / 2)
        let x = min(max(defaultCenter.x + candidate.width, minX), maxX)
        let y = min(max(defaultCenter.y + candidate.height, minY), maxY)
        return CGSize(width: x - defaultCenter.x, height: y - defaultCenter.y)
    }

    private var defaultCenter: CGPoint {
        CGPoint(
            x: expandedPanelSize.width / 2 + 16,
            y: max(
                topPadding + expandedPanelSize.height / 2,
                containerSize.height - bottomPadding - expandedPanelSize.height / 2
            )
        )
    }

    private var previewCanvasColor: Color {
        colorScheme == .dark ? .black : Color(uiColor: .secondarySystemBackground)
    }

    private func panelBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    shape
                        .fill(Color.clear)
                        .glassEffect(.clear, in: shape)
                        .overlay(shape.fill(glassOverlayColor))
                        .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
                        .shadow(color: glassShadowColor, radius: 8, x: 0, y: 3)
                } else {
                    materialBackground(shape: shape)
                }
            } else {
                materialBackground(shape: shape)
            }
        }
    }

    private func materialBackground(shape: RoundedRectangle) -> some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(glassOverlayColor))
            .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
            .shadow(color: glassShadowColor, radius: 8, x: 0, y: 3)
    }

    private var glassOverlayColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.2)
    }

    private var glassStrokeColor: Color {
        Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28)
    }

    private var glassShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1)
    }
}

private struct AgentToolExecutionPreviewDetail: View {
    @Environment(\.dismiss) private var dismiss

    let preview: AgentToolExecutionPreviewSnapshot
    let displayName: String
    let iconName: String
    let browserImage: UIImage?
    let onOpenBrowser: (() -> Void)?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(
                        NSLocalizedString("状态", comment: "Agent tool preview detail state"),
                        value: preview.state == .running
                            ? NSLocalizedString("执行中", comment: "Agent tool preview running")
                            : NSLocalizedString("已完成", comment: "Agent tool preview completed")
                    )
                    LabeledContent(NSLocalizedString("工具", comment: "Agent tool preview detail tool")) {
                        Label(displayName, systemImage: iconName)
                    }
                    if let displayTitle = preview.displayTitle {
                        LabeledContent(
                            NSLocalizedString("任务", comment: "Agent tool preview task title"),
                            value: displayTitle
                        )
                    }
                }

                if browserImage != nil || !preview.previewText.isEmpty {
                    Section {
                        if let browserImage {
                            Image(uiImage: browserImage)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Text(preview.previewText)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    } header: {
                        Text(NSLocalizedString("缩略图内容", comment: "Agent tool chat preview content"))
                    } footer: {
                        Text(NSLocalizedString("这里显示的内容与聊天缩略图一致；执行中显示参数摘要，完成后显示结果末尾。", comment: "Agent tool chat preview content footer"))
                    }
                }

                Section(NSLocalizedString("工具参数", comment: "Agent tool preview arguments")) {
                    Text(preview.arguments.isEmpty ? "{}" : preview.arguments)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    if preview.argumentsWereTruncated {
                        Label(NSLocalizedString("预览已截断", comment: "Agent tool detail preview truncated"), systemImage: "ellipsis")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let result = preview.result, !result.isEmpty {
                    Section(NSLocalizedString("工具结果", comment: "Agent tool preview result")) {
                        Text(result)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        if preview.resultWasTruncated {
                            Label(NSLocalizedString("预览已截断", comment: "Agent tool detail preview truncated"), systemImage: "ellipsis")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let onOpenBrowser {
                    Section {
                        Button {
                            dismiss()
                            onOpenBrowser()
                        } label: {
                            Label(NSLocalizedString("打开浏览器", comment: "Open Browser Agent from tool preview"), systemImage: "safari")
                        }
                    }
                }
            }
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("关闭", comment: "Close Agent tool preview detail")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct LocalLinuxTerminalFloatingPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var terminalPreview = LocalLinuxTerminalPreviewModel()

    let isEnabled: Bool
    let containerSize: CGSize
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    @Binding var offset: CGSize
    @Binding var isCollapsed: Bool
    let isLiquidGlassEnabled: Bool
    let onOpen: (UUID) -> Void

    @State private var dragStartOffset: CGSize?

    private let expandedPanelSize = CGSize(width: 168, height: 112)
    private let collapsedPanelSize = CGSize(width: 44, height: 44)

    private var panelSize: CGSize {
        isCollapsed ? collapsedPanelSize : expandedPanelSize
    }

    var body: some View {
        Group {
            if let activeTerminalID = terminalPreview.activeTerminalID {
                Group {
                    if isCollapsed {
                        collapsedPanelContent()
                            .transition(.opacity.combined(with: .scale(scale: 0.82)))
                            .gesture(
                                dragGesture.exclusively(
                                    before: TapGesture().onEnded { setCollapsed(false) }
                                )
                            )
                    } else {
                        panelContent(jobID: activeTerminalID)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .position(
                    x: defaultCenter.x + clampedOffset.width,
                    y: defaultCenter.y + clampedOffset.height
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 1), value: isCollapsed)
        .task(id: isEnabled) {
            await terminalPreview.observeActivity(isEnabled: isEnabled)
        }
        .task(id: terminalOutputObservationID) {
            await terminalPreview.observeOutput(appearance: terminalAppearance, maximumLines: 10)
        }
    }

    private func collapsedPanelContent() -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "terminal.fill")
                .etFont(.system(size: 17, weight: .semibold))
                .foregroundStyle(TelegramColors.attachButtonColor)

            if terminalPreview.activeTerminalCount > 1 {
                Text("\(terminalPreview.activeTerminalCount)")
                    .etFont(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(TelegramColors.attachButtonColor))
                    .offset(x: 4, y: 4)
            } else {
                Circle()
                    .fill(Color.green)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: collapsedPanelSize.width, height: collapsedPanelSize.height)
        .background(panelBackground(cornerRadius: collapsedPanelSize.width / 2))
        .clipShape(Circle())
        .contentShape(Circle())
        .accessibilityLabel(NSLocalizedString("展开用户终端预览", comment: "Expand user Linux terminal preview"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { setCollapsed(false) }
    }

    private func panelContent(jobID: UUID) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .etFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TelegramColors.attachButtonColor)

                    Text(NSLocalizedString("用户终端", comment: "User terminal preview title"))
                        .etFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if terminalPreview.activeTerminalCount > 1 {
                        Label("\(terminalPreview.activeTerminalCount)", systemImage: "rectangle.stack")
                            .labelStyle(.titleAndIcon)
                            .etFont(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(jobID.uuidString.prefix(4)))
                            .etFont(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .gesture(expandedInteractionGesture(jobID: jobID))

                Button {
                    setCollapsed(true)
                } label: {
                    Image(systemName: "minus")
                        .etFont(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("收起用户终端预览", comment: "Collapse user Linux terminal preview"))
            }
            .padding(.horizontal, 9)
            .frame(height: 30)

            Group {
                if terminalPreview.presentation.plainText.isEmpty {
                    Text(NSLocalizedString("终端正在启动…", comment: "Linux terminal starting placeholder"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(terminalPreview.presentation.attributedText)
                }
            }
            .font(.system(size: 6, design: .monospaced))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(6)
            .background(terminalCanvasColor)
            .contentShape(Rectangle())
            .clipped()
            .gesture(expandedInteractionGesture(jobID: jobID))
            .accessibilityLabel(NSLocalizedString("打开用户终端", comment: "Open user Linux terminal"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen(jobID) }
        }
        .frame(width: expandedPanelSize.width, height: expandedPanelSize.height)
        .background(panelBackground(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if dragStartOffset == nil {
                    dragStartOffset = offset
                }
                let startOffset = dragStartOffset ?? offset
                offset = clamp(
                    CGSize(
                        width: startOffset.width + value.translation.width,
                        height: startOffset.height + value.translation.height
                    ),
                    panelSize: panelSize
                )
            }
            .onEnded { value in
                let startOffset = dragStartOffset ?? offset
                offset = clamp(
                    CGSize(
                        width: startOffset.width + value.translation.width,
                        height: startOffset.height + value.translation.height
                    ),
                    panelSize: panelSize
                )
                dragStartOffset = nil
            }
    }

    private func expandedInteractionGesture(jobID: UUID) -> some Gesture {
        dragGesture.exclusively(
            before: TapGesture().onEnded { onOpen(jobID) }
        )
    }

    private var clampedOffset: CGSize {
        clamp(offset, panelSize: panelSize)
    }

    private var terminalAppearance: LocalLinuxTerminalAppearance {
        colorScheme == .dark ? .dark : .light
    }

    private var terminalCanvasColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var terminalOutputObservationID: String {
        "\(terminalPreview.activeTerminalID?.uuidString ?? "none")|\(terminalAppearance)"
    }

    private func setCollapsed(_ collapsed: Bool) {
        let targetSize = collapsed ? collapsedPanelSize : expandedPanelSize
        withAnimation(.spring(response: 0.32, dampingFraction: 1)) {
            isCollapsed = collapsed
            offset = clamp(offset, panelSize: targetSize)
        }
    }

    private func clamp(_ candidate: CGSize, panelSize: CGSize) -> CGSize {
        let minX = panelSize.width / 2 + 12
        let maxX = max(minX, containerSize.width - panelSize.width / 2 - 12)
        let minY = topPadding + panelSize.height / 2
        let maxY = max(minY, containerSize.height - bottomPadding - panelSize.height / 2)
        let x = min(max(defaultCenter.x + candidate.width, minX), maxX)
        let y = min(max(defaultCenter.y + candidate.height, minY), maxY)
        return CGSize(width: x - defaultCenter.x, height: y - defaultCenter.y)
    }

    private var defaultCenter: CGPoint {
        CGPoint(
            x: expandedPanelSize.width / 2 + 16,
            y: max(
                topPadding + expandedPanelSize.height / 2,
                containerSize.height - bottomPadding - expandedPanelSize.height / 2
            )
        )
    }

    private func panelBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    shape
                        .fill(Color.clear)
                        .glassEffect(.clear, in: shape)
                        .overlay(shape.fill(glassOverlayColor))
                        .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
                        .shadow(color: glassShadowColor, radius: 8, x: 0, y: 3)
                } else {
                    materialBackground(shape: shape)
                }
            } else {
                materialBackground(shape: shape)
            }
        }
    }

    private func materialBackground(shape: RoundedRectangle) -> some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(glassOverlayColor))
            .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
            .shadow(color: glassShadowColor, radius: 8, x: 0, y: 3)
    }

    private var glassOverlayColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.2)
    }

    private var glassStrokeColor: Color {
        Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28)
    }

    private var glassShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1)
    }
}
