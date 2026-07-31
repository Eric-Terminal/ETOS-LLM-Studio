// ============================================================================
// ChatTranscriptSwiftUIImageRenderer.swift
// ============================================================================
// ETOS LLM Studio
//
// 使用真实 SwiftUI 聊天气泡生成 PNG 长图，并通过 UIKit 分屏快照降低超长视图
// 一次性绘制带来的峰值压力。
// ============================================================================

import AVFoundation
import CoreImage
import ETOSCore
import SwiftUI
import UIKit

struct ChatTranscriptSwiftUIImageConfiguration {
    let width: CGFloat
    let viewportHeight: CGFloat
    let title: String
    let subtitle: String
    let inputPlaceholder: String
    let prefersDarkAppearance: Bool
    let locale: Locale
    let rootFont: Font
    let composerInputHeight: CGFloat
    let composerActionIconName: String
    let enableMarkdown: Bool
    let enableBackground: Bool
    let enableLiquidGlass: Bool
    let enableNoBubbleUI: Bool
    let enableAdvancedRenderer: Bool
    let reasoningPreviewMaxHeight: CGFloat
    let backgroundMediaURL: URL?
    let backgroundImage: UIImage?
    let backgroundIsVideo: Bool
    let backgroundOpacity: Double
    let backgroundBlurRadius: Double
    let backgroundContentMode: ContentMode
    let providers: [Provider]
}

@MainActor
enum ChatTranscriptSwiftUIImageRenderer {
    static func render(
        preparedExport: ChatTranscriptPreparedImageExport,
        sourceMessages: [ChatMessage],
        includeReasoning: Bool,
        configuration: ChatTranscriptSwiftUIImageConfiguration
    ) async throws -> Data {
        let preparedMessages = await prepareMessages(
            preparedExport.messages,
            includeReasoning: includeReasoning
        )
        try Task.checkCancellation()

        let attachmentFileNames = preparedMessages.flatMap { $0.message.imageFileNames ?? [] }
        async let attachmentPreload = ChatAttachmentImageCache.preload(
            fileNames: attachmentFileNames
        )
        let resolvedBackgroundImage = await resolveBackgroundImage(configuration: configuration)
        let preloadedAttachments = try await attachmentPreload
        try Task.checkCancellation()

        let rows = makeRows(
            preparedMessages: preparedMessages,
            sourceMessages: sourceMessages,
            includeReasoning: includeReasoning
        )

        let canvas = ChatTranscriptExportCanvas(
            rows: rows,
            continuationContext: preparedExport.continuationContext,
            configuration: configuration,
            backgroundImage: resolvedBackgroundImage
        )
        .environment(\.chatTranscriptPreloadedAttachmentImages, preloadedAttachments.images)
        .environment(\.colorScheme, configuration.prefersDarkAppearance ? .dark : .light)
        .environment(\.locale, configuration.locale)
        .environment(\.font, configuration.rootFont)
        .frame(width: configuration.width)
        .fixedSize(horizontal: false, vertical: true)

        let capturedImage = try await ChatTranscriptSwiftUIImageCapture.capture(
            canvas: canvas,
            width: configuration.width,
            viewportHeight: configuration.viewportHeight,
            prefersDarkAppearance: configuration.prefersDarkAppearance
        )
        return try await encodePNG(capturedImage.image, scale: capturedImage.scale)
    }

    private static func prepareMessages(
        _ messages: [ChatMessage],
        includeReasoning: Bool
    ) async -> [ChatTranscriptPreparedMessage] {
        let visualPairs = await Task.detached(priority: .userInitiated) {
            let rules = MessageRegexRuleStore.currentRules()
            return messages.map { sourceMessage -> (ChatMessage, ChatMessage) in
                var message = sourceMessage
                if !includeReasoning {
                    message.reasoningContent = nil
                }
                let visualMessage = ChatService.visualMessage(from: message, rules: rules)
                return (message, visualMessage)
            }
        }.value

        return await withTaskGroup(of: ChatTranscriptPreparedMessage.self) { group in
            for (index, pair) in visualPairs.enumerated() {
                group.addTask {
                    let markdown = await ETMarkdownPrecomputeWorker.shared.prepare(source: pair.1.content)
                    let reasoningMarkdown: ETPreparedMarkdownRenderPayload?
                    if let reasoning = pair.1.reasoningContent,
                       !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        reasoningMarkdown = await ETMarkdownPrecomputeWorker.shared.prepare(source: reasoning)
                    } else {
                        reasoningMarkdown = nil
                    }
                    return ChatTranscriptPreparedMessage(
                        index: index,
                        message: pair.0,
                        visualMessage: pair.1,
                        markdown: markdown,
                        reasoningMarkdown: reasoningMarkdown
                    )
                }
            }

            var results: [ChatTranscriptPreparedMessage] = []
            results.reserveCapacity(visualPairs.count)
            for await item in group {
                results.append(item)
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    private static func makeRows(
        preparedMessages: [ChatTranscriptPreparedMessage],
        sourceMessages: [ChatMessage],
        includeReasoning: Bool
    ) -> [ChatTranscriptRenderedRow] {
        let displaySourceMessages = ChatTranscriptExportService.visibleImageMessages(
            from: sourceMessages
        )
        let sourceIndexByID: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: displaySourceMessages.enumerated().map {
                ($0.element.id, $0.offset)
            }
        )
        let retryableMessageIDs = MessageActionBarAvailability.retryableMessageIDs(
            in: sourceMessages,
            isSending: false
        )

        return preparedMessages.enumerated().map { index, prepared in
            let previous = index > 0 ? preparedMessages[index - 1].message : nil
            let next = index + 1 < preparedMessages.count ? preparedMessages[index + 1].message : nil
            let mergesWithPrevious = areOriginalNeighbors(
                previous,
                prepared.message,
                sourceIndexByID: sourceIndexByID
            ) && shouldMerge(previous, prepared.message)
            let mergesWithNext = areOriginalNeighbors(
                prepared.message,
                next,
                sourceIndexByID: sourceIndexByID
            ) && shouldMerge(prepared.message, next)
            let continuesActionBar = areOriginalNeighbors(
                prepared.message,
                next,
                sourceIndexByID: sourceIndexByID
            ) && (mergesWithNext || (prepared.message.role == .user && next?.role == .user))
            let connectsFromPrevious = mergesWithPrevious
                && hasTimelineContent(previous)
                && hasTimelineContent(prepared.message)
            let connectsToNext = mergesWithNext
                && hasTimelineContent(prepared.message)
                && hasTimelineContent(next)

            let state = ChatMessageRenderState(message: prepared.message)
            state.updateVisualMessage(prepared.visualMessage)
            return ChatTranscriptRenderedRow(
                id: prepared.message.id,
                state: state,
                markdown: prepared.markdown,
                reasoningMarkdown: prepared.reasoningMarkdown,
                reasoningThinkingTitle: prepared.reasoningMarkdown?.thinkingTitle,
                isReasoningExpanded: includeReasoning,
                mergeWithPrevious: mergesWithPrevious,
                mergeWithNext: mergesWithNext,
                messageActionBarContinuesToNext: continuesActionBar,
                connectsTimelineFromPrevious: connectsFromPrevious,
                connectsTimelineToNext: connectsToNext,
                responseAttemptVersionInfo: ChatResponseAttemptSupport.versionInfo(
                    for: prepared.message,
                    in: sourceMessages
                ),
                canRetry: retryableMessageIDs.contains(prepared.message.id),
                disablesAdvancedRenderer: prepared.markdown.containsMermaidContent
                    || prepared.reasoningMarkdown?.containsMermaidContent == true
            )
        }
    }

    private static func areOriginalNeighbors(
        _ lhs: ChatMessage?,
        _ rhs: ChatMessage?,
        sourceIndexByID: [UUID: Int]
    ) -> Bool {
        guard let lhs, let rhs,
              let lhsIndex = sourceIndexByID[lhs.id],
              let rhsIndex = sourceIndexByID[rhs.id] else {
            return false
        }
        return rhsIndex == lhsIndex + 1
    }

    private static func shouldMerge(_ lhs: ChatMessage?, _ rhs: ChatMessage?) -> Bool {
        guard let lhs, let rhs else { return false }
        return ChatResponseAttemptSupport.shouldMergeAdjacentAssistantTurnMessages(lhs, rhs)
    }

    private static func hasTimelineContent(_ message: ChatMessage?) -> Bool {
        guard let message else { return false }
        switch message.role {
        case .assistant, .tool, .system:
            break
        case .user, .error:
            return false
        @unknown default:
            return false
        }

        let hasReasoning = !(message.reasoningContent ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let hasToolCall = (message.toolCalls ?? []).contains {
            $0.toolName != AppToolKind.showWidget.toolName
        }
        return hasReasoning || hasToolCall
    }

    private static func resolveBackgroundImage(
        configuration: ChatTranscriptSwiftUIImageConfiguration
    ) async -> UIImage? {
        guard configuration.enableBackground else { return nil }
        if let image = configuration.backgroundImage {
            return image
        }
        guard let url = configuration.backgroundMediaURL else { return nil }
        let isVideo = configuration.backgroundIsVideo
        let blurRadius = configuration.backgroundBlurRadius

        let box = await Task.detached(priority: .userInitiated) {
            let sourceImage: UIImage?
            if isVideo {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 1_290, height: 2_796)
                let previewTime = CMTime(seconds: 0.1, preferredTimescale: 600)
                if let cgImage = try? generator.copyCGImage(at: previewTime, actualTime: nil) {
                    sourceImage = UIImage(cgImage: cgImage)
                } else {
                    sourceImage = nil
                }
            } else {
                sourceImage = UIImage(contentsOfFile: url.path)
            }

            guard let sourceImage, blurRadius > 0.01,
                  let ciImage = CIImage(image: sourceImage) else {
                return ChatTranscriptImageBox(sourceImage)
            }
            let extent = ciImage.extent
            let output = ciImage
                .clampedToExtent()
                .applyingFilter(
                    "CIGaussianBlur",
                    parameters: [kCIInputRadiusKey: blurRadius]
                )
                .cropped(to: extent)
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let blurredCGImage = context.createCGImage(output, from: extent) else {
                return ChatTranscriptImageBox(sourceImage)
            }
            return ChatTranscriptImageBox(
                UIImage(
                    cgImage: blurredCGImage,
                    scale: sourceImage.scale,
                    orientation: sourceImage.imageOrientation
                )
            )
        }.value
        return box.image
    }

    private static func encodePNG(_ cgImage: CGImage, scale: CGFloat) async throws -> Data {
        let imageBox = ChatTranscriptCGImageBox(cgImage)
        return try await Task.detached(priority: .userInitiated) {
            guard let data = UIImage(
                cgImage: imageBox.image,
                scale: scale,
                orientation: .up
            ).pngData() else {
                throw ChatTranscriptExportError.imageRenderFailed
            }
            return data
        }.value
    }

}

private struct ChatTranscriptPreparedMessage: @unchecked Sendable {
    let index: Int
    let message: ChatMessage
    let visualMessage: ChatMessage
    let markdown: ETPreparedMarkdownRenderPayload
    let reasoningMarkdown: ETPreparedMarkdownRenderPayload?
}

private struct ChatTranscriptRenderedRow: Identifiable {
    let id: UUID
    let state: ChatMessageRenderState
    let markdown: ETPreparedMarkdownRenderPayload
    let reasoningMarkdown: ETPreparedMarkdownRenderPayload?
    let reasoningThinkingTitle: String?
    let isReasoningExpanded: Bool
    let mergeWithPrevious: Bool
    let mergeWithNext: Bool
    let messageActionBarContinuesToNext: Bool
    let connectsTimelineFromPrevious: Bool
    let connectsTimelineToNext: Bool
    let responseAttemptVersionInfo: ChatResponseAttemptVersionInfo?
    let canRetry: Bool
    let disablesAdvancedRenderer: Bool
}

@MainActor
private struct ChatTranscriptExportCanvas: View {
    let rows: [ChatTranscriptRenderedRow]
    let continuationContext: ConversationContinuationContext?
    let configuration: ChatTranscriptSwiftUIImageConfiguration
    let backgroundImage: UIImage?

    var body: some View {
        ChatTranscriptExportForeground(
            rows: rows,
            continuationContext: continuationContext,
            configuration: configuration
        )
        .background(alignment: .top) {
            GeometryReader { proxy in
                let height = max(1, proxy.size.height)
                ChatTranscriptExportWallpaper(
                    configuration: configuration,
                    image: backgroundImage,
                    totalHeight: height,
                    tileCount: max(1, Int(ceil(height / configuration.viewportHeight)))
                )
            }
        }
        .frame(width: configuration.width)
        .clipped()
    }
}

@MainActor
private struct ChatTranscriptExportForeground: View {
    let rows: [ChatTranscriptRenderedRow]
    let continuationContext: ConversationContinuationContext?
    let configuration: ChatTranscriptSwiftUIImageConfiguration

    var body: some View {
        VStack(spacing: 0) {
            ChatTranscriptExportHeader(configuration: configuration)

            VStack(spacing: 0) {
                if let continuationContext {
                    ChatTranscriptContinuationContextCard(context: continuationContext)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }

                ForEach(rows) { row in
                    ChatBubble(
                        messageState: row.state,
                        layoutWidth: max(1, configuration.width - 16),
                        reasoningPreviewMaxHeight: configuration.reasoningPreviewMaxHeight,
                        preparedMarkdownPayload: row.markdown,
                        preparedReasoningMarkdownPayload: row.reasoningMarkdown,
                        reasoningThinkingTitle: row.reasoningThinkingTitle,
                        isReasoningExpanded: .constant(row.isReasoningExpanded),
                        isReasoningAutoPreview: false,
                        isToolCallsExpanded: .constant(false),
                        enableMarkdown: configuration.enableMarkdown,
                        enableBackground: configuration.enableBackground,
                        enableLiquidGlass: configuration.enableLiquidGlass,
                        enableNoBubbleUI: configuration.enableNoBubbleUI,
                        enableAdvancedRenderer: configuration.enableAdvancedRenderer
                            && !row.disablesAdvancedRenderer,
                        enableExperimentalToolResultDisplay: true,
                        enableMathRendering: configuration.enableAdvancedRenderer,
                        showsStreamingIndicators: false,
                        mergeWithPrevious: row.mergeWithPrevious,
                        mergeWithNext: row.mergeWithNext,
                        messageActionBarContinuesToNext: row.messageActionBarContinuesToNext,
                        connectsTimelineFromPrevious: row.connectsTimelineFromPrevious,
                        connectsTimelineToNext: row.connectsTimelineToNext,
                        responseAttemptVersionInfo: row.responseAttemptVersionInfo,
                        hasAutoOpenedPendingToolCall: { _ in true },
                        markPendingToolCallAutoOpened: { _ in },
                        canRetry: row.canRetry,
                        onRetry: {},
                        onCopy: {},
                        onSwitchToPreviousVersion: {},
                        onSwitchToNextVersion: {},
                        isSelectionMode: false,
                        isSelected: false,
                        onToggleSelection: {},
                        onOpenMore: nil,
                        providers: configuration.providers
                    )
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .frame(width: configuration.width)

            ChatTranscriptExportComposer(configuration: configuration)
        }
        .frame(width: configuration.width)
    }
}

private struct ChatTranscriptContinuationContextCard: View {
    let context: ConversationContinuationContext

    var body: some View {
        VStack(alignment: .leading) {
            Label(
                NSLocalizedString("续聊上下文", comment: "Continuation context export card title"),
                systemImage: "rectangle.compress.vertical"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tint)

            Text(String(
                format: NSLocalizedString("来自“%@”", comment: "Continuation context export source"),
                context.sourceSessionNameSnapshot
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(context.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if !context.retainedMessages.isEmpty {
                Divider()
                Text(NSLocalizedString("最近对话原文", comment: "Continuation context retained messages heading"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(context.retainedMessages) { message in
                    VStack(alignment: .leading) {
                        Text(roleTitle(message.role))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(message.content)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
        }
    }

    private func roleTitle(_ role: MessageRole) -> String {
        switch role {
        case .system: return NSLocalizedString("系统", comment: "Continuation export role")
        case .user: return NSLocalizedString("用户", comment: "Continuation export role")
        case .assistant: return NSLocalizedString("助手", comment: "Continuation export role")
        case .tool: return NSLocalizedString("工具", comment: "Continuation export role")
        case .error: return NSLocalizedString("错误", comment: "Continuation export role")
        }
    }
}

private struct ChatTranscriptExportWallpaper: View {
    let configuration: ChatTranscriptSwiftUIImageConfiguration
    let image: UIImage?
    let totalHeight: CGFloat
    let tileCount: Int

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<tileCount, id: \.self) { _ in
                ChatTranscriptExportWallpaperTile(configuration: configuration, image: image)
                    .frame(width: configuration.width, height: configuration.viewportHeight)
                    .clipped()
            }
        }
        .frame(width: configuration.width, height: totalHeight, alignment: .top)
        .clipped()
    }
}

private struct ChatTranscriptExportWallpaperTile: View {
    let configuration: ChatTranscriptSwiftUIImageConfiguration
    let image: UIImage?

    var body: some View {
        ZStack {
            (configuration.prefersDarkAppearance
                ? Color.black
                : Color(uiColor: .systemBackground))

            if configuration.enableBackground, let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: configuration.backgroundContentMode)
                    .frame(width: configuration.width, height: configuration.viewportHeight)
                    .clipped()
                    .opacity(min(max(configuration.backgroundOpacity, 0), 1))
            } else {
                TelegramDefaultBackground()
            }
        }
    }
}

private struct ChatTranscriptExportHeader: View {
    let configuration: ChatTranscriptSwiftUIImageConfiguration
    private let controlSize: CGFloat = 46

    var body: some View {
        HStack(spacing: 12) {
            headerIcon("list.bullet")
            Spacer(minLength: 12)
            VStack(spacing: 1) {
                Text(configuration.title)
                    .etFont(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if !configuration.subtitle.isEmpty {
                    Text(configuration.subtitle)
                        .etFont(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 6)
            .frame(maxWidth: max(90, configuration.width - 164))
            .frame(height: controlSize)
            .background(headerPillBackground)
            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.6))
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.down")
                    .etFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 10)
            }
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
            .layoutPriority(1)

            Spacer(minLength: 12)
            headerIcon("gearshape")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .etFont(.system(size: 17, weight: .semibold))
            .foregroundStyle(TelegramColors.navBarText)
            .frame(width: controlSize, height: controlSize)
            .background(headerCircleBackground)
            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
    }

    @ViewBuilder
    private var headerCircleBackground: some View {
        if configuration.enableLiquidGlass {
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(Color.clear)
                    .glassEffect(.clear, in: Circle())
                    .overlay(Circle().fill(glassOverlayColor))
            } else {
                materialCircle
            }
        } else {
            materialCircle
        }
    }

    @ViewBuilder
    private var headerPillBackground: some View {
        if configuration.enableLiquidGlass {
            if #available(iOS 26.0, *) {
                Capsule()
                    .fill(Color.clear)
                    .glassEffect(.clear, in: Capsule())
                    .overlay(Capsule().fill(glassOverlayColor))
            } else {
                materialPill
            }
        } else {
            materialPill
        }
    }

    private var materialCircle: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(Circle().fill(glassOverlayColor))
    }

    private var materialPill: some View {
        Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().fill(glassOverlayColor))
    }

    private var glassOverlayColor: Color {
        configuration.prefersDarkAppearance ? .black.opacity(0.24) : .white.opacity(0.2)
    }
}

private struct ChatTranscriptExportComposer: View {
    let configuration: ChatTranscriptSwiftUIImageConfiguration
    private let controlSize: CGFloat = 40

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            composerIcon("paperclip")

            HStack {
                Text(configuration.inputPlaceholder)
                    .etFont(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 18)
            }
            .frame(maxWidth: .infinity, minHeight: configuration.composerInputHeight, alignment: .leading)
            .background(
                roundedMaterial(cornerRadius: configuration.composerInputHeight / 2)
            )

            composerIcon(configuration.composerActionIconName)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.bottom, 6)
    }

    private func composerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .etFont(.system(size: 18, weight: .semibold))
            .foregroundStyle(TelegramColors.attachButtonColor)
            .frame(width: controlSize, height: controlSize)
            .background(circleMaterial)
    }

    @ViewBuilder
    private var circleMaterial: some View {
        if configuration.enableLiquidGlass {
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(Color.clear)
                    .glassEffect(.clear, in: Circle())
                    .overlay(Circle().fill(glassOverlayColor))
                    .overlay(Circle().stroke(glassStrokeColor, lineWidth: 0.5))
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            } else {
                materialCircle
            }
        } else {
            materialCircle
        }
    }

    private var materialCircle: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(Circle().fill(glassOverlayColor))
            .overlay(Circle().stroke(glassStrokeColor, lineWidth: 0.5))
            .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
    }

    @ViewBuilder
    private func roundedMaterial(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if configuration.enableLiquidGlass {
            if #available(iOS 26.0, *) {
                shape
                    .fill(Color.clear)
                    .glassEffect(.clear, in: shape)
                    .overlay(shape.fill(glassOverlayColor))
                    .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            } else {
                materialRoundedRectangle(shape)
            }
        } else {
            materialRoundedRectangle(shape)
        }
    }

    private func materialRoundedRectangle(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(glassOverlayColor))
            .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
            .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
    }

    private var glassOverlayColor: Color {
        configuration.prefersDarkAppearance ? .black.opacity(0.24) : .white.opacity(0.2)
    }

    private var glassStrokeColor: Color {
        Color.white.opacity(configuration.prefersDarkAppearance ? 0.18 : 0.28)
    }

    private var glassShadowColor: Color {
        Color.black.opacity(configuration.prefersDarkAppearance ? 0.3 : 0.1)
    }
}

private final class ChatTranscriptImageBox: @unchecked Sendable {
    let image: UIImage?

    nonisolated init(_ image: UIImage?) {
        self.image = image
    }
}

private final class ChatTranscriptCGImageBox: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

extension ChatView {
    func transcriptSwiftUIImageConfiguration(
        session: ChatSession?
    ) -> ChatTranscriptSwiftUIImageConfiguration {
        let windowBounds = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .bounds ?? UIScreen.main.bounds
        let exportWidth = min(430, max(1, windowBounds.width))
        let viewportHeight = max(1, windowBounds.height)
        let measuredPointSize = CGFloat(
            FontLibrary.scaledPointSize(
                16,
                scale: appConfig.fontCustomScale,
                isCustomFontEnabled: appConfig.fontUseCustomFonts
            )
        )
        let composerInputHeight = max(
            44,
            UIFont.systemFont(ofSize: measuredPointSize).lineHeight + 24
        )
        let title = session?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 }
            ?? NSLocalizedString("新的对话", comment: "聊天长图未命名会话标题")
        let subtitle = viewModel.activatedConversationModels.isEmpty
            ? NSLocalizedString("选择模型以开始", comment: "聊天长图未选择模型提示")
            : modelSubtitle
        let actionIconName: String
        if viewModel.canQuickRetryLatestMessage {
            actionIconName = "arrow.clockwise"
        } else if viewModel.enableSpeechInput {
            actionIconName = "mic.fill"
        } else {
            actionIconName = "arrow.up"
        }

        return ChatTranscriptSwiftUIImageConfiguration(
            width: exportWidth,
            viewportHeight: viewportHeight,
            title: resolvedTitle,
            subtitle: subtitle,
            inputPlaceholder: NSLocalizedString("Message", comment: "聊天长图输入框占位文本"),
            prefersDarkAppearance: colorScheme == .dark,
            locale: AppLanguagePreference.preferredLocale(rawValue: appConfig.appLanguage),
            rootFont: AppFontAdapter.adaptedFont(
                from: .body,
                sampleText: "The quick brown fox 你好こんにちは"
            ),
            composerInputHeight: composerInputHeight,
            composerActionIconName: actionIconName,
            enableMarkdown: viewModel.enableMarkdown,
            enableBackground: viewModel.enableBackground,
            enableLiquidGlass: isLiquidGlassEnabled,
            enableNoBubbleUI: viewModel.enableNoBubbleUI,
            enableAdvancedRenderer: viewModel.enableAdvancedRenderer,
            reasoningPreviewMaxHeight: responsiveReasoningPreviewMaxHeight(for: viewportHeight),
            backgroundMediaURL: viewModel.currentBackgroundMediaURL,
            backgroundImage: viewModel.currentBackgroundImageBlurredUIImage,
            backgroundIsVideo: viewModel.currentBackgroundIsVideo,
            backgroundOpacity: viewModel.backgroundOpacity,
            backgroundBlurRadius: viewModel.backgroundBlur,
            backgroundContentMode: viewModel.backgroundContentMode == "fit" ? .fit : .fill,
            providers: viewModel.providers
        )
    }
}
