// ============================================================================
// WatchChatTranscriptImageRenderer.swift
// ============================================================================
// watchOS 聊天长图渲染器
// - 在后台准备 Markdown、附件与壁纸资源
// - 在主线程使用真实 ChatBubble 生成 SwiftUI 离屏快照
// ============================================================================

import SwiftUI
import WatchKit
import Foundation
import ImageIO
import ETOSCore

struct WatchChatTranscriptImageConfiguration: Sendable {
    enum BackgroundContentMode: Sendable {
        case fill
        case fit
    }

    let title: String
    let inputPlaceholder: String
    let prefersDarkAppearance: Bool
    let appLanguage: String
    let backgroundImageURL: URL?
    let backgroundOpacity: Double
    let backgroundBlurRadius: Double
    let backgroundContentMode: BackgroundContentMode
    let enableBackground: Bool
    let enableMarkdown: Bool
    let enableLiquidGlass: Bool
    let enableNoBubbleUI: Bool
    let enableAdvancedRenderer: Bool
    let enableSpeechInput: Bool
    let allowsMessageMerging: Bool
    let inputControlHeight: CGFloat
    let canvasWidth: CGFloat
    let backgroundTileHeight: CGFloat
    let displayScale: CGFloat
}

@MainActor
enum WatchChatTranscriptImageRenderer {
    private static let maximumPixelHeight: CGFloat = 50_000
    private static let maximumBitmapBytes: CGFloat = 40 * 1_024 * 1_024

    static func render(
        preparedExport: ChatTranscriptPreparedImageExport,
        sourceMessages: [ChatMessage],
        includeReasoning: Bool,
        configuration: WatchChatTranscriptImageConfiguration,
        providers: [Provider]
    ) async throws -> ChatTranscriptExportOutput {
        async let assetsTask = prepareAssets(
            messages: preparedExport.messages,
            backgroundImageURL: configuration.backgroundImageURL
        )
        let preparedRows = try await prepareRows(
            messages: preparedExport.messages,
            sourceMessages: sourceMessages,
            includeReasoning: includeReasoning,
            enableMarkdown: configuration.enableMarkdown,
            allowsMessageMerging: configuration.allowsMessageMerging
        )
        let assets = try await assetsTask
        try Task.checkCancellation()

        let rows = preparedRows.map(WatchChatTranscriptRenderRow.init)
        let rootFont = AppFontAdapter.adaptedFont(from: .body)
        let canvas = WatchChatTranscriptCanvas(
            rows: rows,
            configuration: configuration,
            backgroundImage: assets.backgroundImage,
            providers: providers
        )
        .environment(\.watchChatPreloadedAttachmentImages, assets.attachmentImages)
        .environment(
            \.colorScheme,
            configuration.prefersDarkAppearance ? ColorScheme.dark : ColorScheme.light
        )
        .environment(
            \.locale,
            AppLanguagePreference.preferredLocale(rawValue: configuration.appLanguage)
        )
        .environment(\.font, rootFont)
        .frame(width: configuration.canvasWidth)
        .fixedSize(horizontal: false, vertical: true)

        let renderer = ImageRenderer(content: canvas)
        renderer.proposedSize = ProposedViewSize(width: configuration.canvasWidth, height: nil)
        renderer.isOpaque = true

        var measuredSize = CGSize.zero
        renderer.render(rasterizationScale: 1) { size, _ in
            measuredSize = size
        }
        guard measuredSize.width > 0, measuredSize.height > 0 else {
            throw ChatTranscriptExportError.imageRenderFailed
        }

        let outputScale = try resolvedOutputScale(
            for: measuredSize,
            preferredScale: configuration.displayScale
        )
        renderer.scale = outputScale
        try Task.checkCancellation()

        guard let image = renderer.cgImage else {
            throw ChatTranscriptExportError.imageRenderFailed
        }
        let data = try await encodePNG(image)
        return preparedExport.output(data: data)
    }

    private static func resolvedOutputScale(
        for size: CGSize,
        preferredScale: CGFloat
    ) throws -> CGFloat {
        let preferred = min(max(preferredScale, 1), 2)
        let candidates = preferred > 1 ? [preferred, 1] : [CGFloat(1)]

        for scale in candidates {
            let pixelWidth = ceil(size.width * scale)
            let pixelHeight = ceil(size.height * scale)
            let estimatedBytes = pixelWidth * pixelHeight * 4
            if pixelHeight <= maximumPixelHeight, estimatedBytes <= maximumBitmapBytes {
                return scale
            }
        }
        throw ChatTranscriptExportError.imageTooLong
    }

    nonisolated private static func prepareRows(
        messages: [ChatMessage],
        sourceMessages: [ChatMessage],
        includeReasoning: Bool,
        enableMarkdown: Bool,
        allowsMessageMerging: Bool
    ) async throws -> [WatchChatTranscriptPreparedRow] {
        let messagePairs = try await Task.detached(priority: .userInitiated) {
            let rules = MessageRegexRuleStore.currentRules()
            return try messages.map { sourceMessage -> (ChatMessage, ChatMessage) in
                try Task.checkCancellation()
                var message = sourceMessage
                if !includeReasoning {
                    message.reasoningContent = nil
                }
                return (message, ChatService.visualMessage(from: message, rules: rules))
            }
        }.value
        let displayedMessages = messagePairs.map(\.0)
        let visualMessages = messagePairs.map(\.1)
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

        var markdownByMessageID: [UUID: ETPreparedMarkdownRenderPayload] = [:]
        var reasoningMarkdownByMessageID: [UUID: ETPreparedMarkdownRenderPayload] = [:]
        if enableMarkdown {
            markdownByMessageID.reserveCapacity(displayedMessages.count)
            reasoningMarkdownByMessageID.reserveCapacity(displayedMessages.count)
            for message in visualMessages {
                try Task.checkCancellation()
                if !message.content.isEmpty {
                    markdownByMessageID[message.id] = await ETMarkdownPrecomputeWorker.shared.prepare(
                        source: message.content
                    )
                }
                if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                    reasoningMarkdownByMessageID[message.id] = await ETMarkdownPrecomputeWorker.shared.prepare(
                        source: reasoning
                    )
                }
            }
        }

        return displayedMessages.indices.map { index in
            let message = displayedMessages[index]
            let visualMessage = visualMessages[index]
            let previous = index > 0 ? displayedMessages[index - 1] : nil
            let next = index + 1 < displayedMessages.count ? displayedMessages[index + 1] : nil
            let isPreviousNeighbor = areOriginalNeighbors(
                previous,
                message,
                sourceIndexByID: sourceIndexByID
            )
            let isNextNeighbor = areOriginalNeighbors(
                message,
                next,
                sourceIndexByID: sourceIndexByID
            )
            let mergeWithPrevious = allowsMessageMerging && isPreviousNeighbor
                && shouldMerge(previous, message)
            let mergeWithNext = allowsMessageMerging && isNextNeighbor
                && shouldMerge(message, next)
            return WatchChatTranscriptPreparedRow(
                message: message,
                visualMessage: visualMessage,
                preparedMarkdownPayload: markdownByMessageID[message.id],
                preparedReasoningMarkdownPayload: reasoningMarkdownByMessageID[message.id],
                reasoningThinkingTitle: reasoningMarkdownByMessageID[message.id]?.thinkingTitle,
                mergeWithPrevious: mergeWithPrevious,
                mergeWithNext: mergeWithNext,
                messageActionBarContinuesToNext: isNextNeighbor
                    && (mergeWithNext || (message.role == .user && next?.role == .user)),
                connectsTimelineFromPrevious: mergeWithPrevious
                    && hasTimelineContent(previous)
                    && hasTimelineContent(message),
                connectsTimelineToNext: mergeWithNext
                    && hasTimelineContent(message)
                    && hasTimelineContent(next),
                responseAttemptVersionInfo: ChatResponseAttemptSupport.versionInfo(
                    for: message,
                    in: sourceMessages
                ),
                canRetry: retryableMessageIDs.contains(message.id)
            )
        }
    }

    nonisolated private static func areOriginalNeighbors(
        _ message: ChatMessage?,
        _ nextMessage: ChatMessage?,
        sourceIndexByID: [UUID: Int]
    ) -> Bool {
        guard let message, let nextMessage,
              let index = sourceIndexByID[message.id],
              let nextIndex = sourceIndexByID[nextMessage.id] else {
            return false
        }
        return nextIndex == index + 1
    }

    nonisolated private static func shouldMerge(
        _ message: ChatMessage?,
        _ nextMessage: ChatMessage?
    ) -> Bool {
        guard let message, let nextMessage else { return false }
        return ChatResponseAttemptSupport.shouldMergeAdjacentAssistantTurnMessages(message, nextMessage)
    }

    nonisolated private static func hasTimelineContent(_ message: ChatMessage?) -> Bool {
        guard let message else { return false }
        switch message.role {
        case .assistant, .system, .tool:
            break
        case .user, .error:
            return false
        @unknown default:
            return false
        }
        let hasReasoning = !(message.reasoningContent ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let hasVisibleToolCall = (message.toolCalls ?? []).contains {
            $0.toolName != AppToolKind.showWidget.toolName
        }
        return hasReasoning || hasVisibleToolCall
    }

    nonisolated private static func prepareAssets(
        messages: [ChatMessage],
        backgroundImageURL: URL?
    ) async throws -> WatchChatTranscriptPreparedAssets {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let backgroundImage = backgroundImageURL.flatMap {
                thumbnailImage(at: $0, fallbackData: nil, maximumPixelSize: 1_024)
            }

            let fileNames = Set(messages.flatMap { $0.imageFileNames ?? [] })
            var attachmentImages: [String: UIImage] = [:]
            attachmentImages.reserveCapacity(fileNames.count)
            for fileName in fileNames {
                try Task.checkCancellation()
                let fileURL = Persistence.getImageDirectory().appendingPathComponent(fileName)
                if let image = thumbnailImage(
                    at: fileURL,
                    fallbackData: Persistence.loadImage(fileName: fileName),
                    maximumPixelSize: 512
                ) {
                    attachmentImages[fileName] = image
                }
            }
            return WatchChatTranscriptPreparedAssets(
                backgroundImage: backgroundImage,
                attachmentImages: attachmentImages
            )
        }.value
    }

    nonisolated private static func thumbnailImage(
        at url: URL,
        fallbackData: Data?,
        maximumPixelSize: Int
    ) -> UIImage? {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            ?? fallbackData.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    nonisolated private static func encodePNG(_ image: CGImage) async throws -> Data {
        let sendableImage = WatchChatTranscriptSendableCGImage(image: image)
        return try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data,
                "public.png" as CFString,
                1,
                nil
            ) else {
                throw ChatTranscriptExportError.imageRenderFailed
            }
            CGImageDestinationAddImage(destination, sendableImage.image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ChatTranscriptExportError.imageRenderFailed
            }
            return data as Data
        }.value
    }
}

private struct WatchChatTranscriptPreparedAssets: @unchecked Sendable {
    let backgroundImage: UIImage?
    let attachmentImages: [String: UIImage]
}

private struct WatchChatTranscriptSendableCGImage: @unchecked Sendable {
    let image: CGImage
}

private struct WatchChatTranscriptPreparedRow: @unchecked Sendable {
    let message: ChatMessage
    let visualMessage: ChatMessage
    let preparedMarkdownPayload: ETPreparedMarkdownRenderPayload?
    let preparedReasoningMarkdownPayload: ETPreparedMarkdownRenderPayload?
    let reasoningThinkingTitle: String?
    let mergeWithPrevious: Bool
    let mergeWithNext: Bool
    let messageActionBarContinuesToNext: Bool
    let connectsTimelineFromPrevious: Bool
    let connectsTimelineToNext: Bool
    let responseAttemptVersionInfo: ChatResponseAttemptVersionInfo?
    let canRetry: Bool
}

private struct WatchChatTranscriptRenderRow: Identifiable {
    let id: UUID
    let messageState: ChatMessageRenderState
    let preparedMarkdownPayload: ETPreparedMarkdownRenderPayload?
    let preparedReasoningMarkdownPayload: ETPreparedMarkdownRenderPayload?
    let reasoningThinkingTitle: String?
    let mergeWithPrevious: Bool
    let mergeWithNext: Bool
    let messageActionBarContinuesToNext: Bool
    let connectsTimelineFromPrevious: Bool
    let connectsTimelineToNext: Bool
    let responseAttemptVersionInfo: ChatResponseAttemptVersionInfo?
    let canRetry: Bool

    @MainActor
    init(_ prepared: WatchChatTranscriptPreparedRow) {
        id = prepared.message.id
        messageState = ChatMessageRenderState(message: prepared.message)
        messageState.updateVisualMessage(prepared.visualMessage)
        preparedMarkdownPayload = prepared.preparedMarkdownPayload
        preparedReasoningMarkdownPayload = prepared.preparedReasoningMarkdownPayload
        reasoningThinkingTitle = prepared.reasoningThinkingTitle
        mergeWithPrevious = prepared.mergeWithPrevious
        mergeWithNext = prepared.mergeWithNext
        messageActionBarContinuesToNext = prepared.messageActionBarContinuesToNext
        connectsTimelineFromPrevious = prepared.connectsTimelineFromPrevious
        connectsTimelineToNext = prepared.connectsTimelineToNext
        responseAttemptVersionInfo = prepared.responseAttemptVersionInfo
        canRetry = prepared.canRetry
    }
}

@MainActor
private struct WatchChatTranscriptCanvas: View {
    let rows: [WatchChatTranscriptRenderRow]
    let configuration: WatchChatTranscriptImageConfiguration
    let backgroundImage: UIImage?
    let providers: [Provider]

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    WatchChatTranscriptBubbleRow(
                        row: row,
                        configuration: configuration,
                        providers: providers
                    )
                }
            }

            composer
        }
        .frame(maxWidth: .infinity)
        .background {
            WatchChatTranscriptRepeatedBackground(
                image: backgroundImage,
                configuration: configuration
            )
        }
        .clipped()
    }

    private var header: some View {
        Text(configuration.title)
            .etFont(.headline, sampleText: configuration.title)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                if !configuration.enableBackground {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        Rectangle().fill(
                            Color.black.opacity(configuration.prefersDarkAppearance ? 0.12 : 0.04)
                        )
                    }
                }
            }
    }

    private var composer: some View {
        HStack(spacing: configuration.enableLiquidGlass ? 10 : 12) {
            composerInputField

            composerActionButton
        }
        .frame(height: configuration.inputControlHeight)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background {
            if !configuration.enableBackground && !configuration.enableLiquidGlass {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
    }

    @ViewBuilder
    private var composerInputField: some View {
        let label = Text(configuration.inputPlaceholder)
            .etFont(.body, sampleText: configuration.inputPlaceholder)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: configuration.inputControlHeight, alignment: .leading)
            .padding(.horizontal, 12)

        if configuration.enableLiquidGlass {
            if #available(watchOS 26.0, *) {
                label.glassEffect(.clear, in: Capsule())
            } else {
                composerInputFallback(label)
            }
        } else {
            composerInputFallback(label)
        }
    }

    @ViewBuilder
    private func composerInputFallback<Content: View>(_ content: Content) -> some View {
        content
            .background(Capsule().fill(inputFillColor))
            .overlay(Capsule().stroke(inputStrokeColor, lineWidth: 0.6))
    }

    @ViewBuilder
    private var composerActionButton: some View {
        let icon = Image(systemName: configuration.enableSpeechInput ? "mic.fill" : "arrow.up")
            .etFont(.system(size: 18, weight: .medium))
            .frame(width: configuration.inputControlHeight, height: configuration.inputControlHeight)
            .foregroundStyle(configuration.enableSpeechInput ? Color.primary : Color.secondary)

        if configuration.enableLiquidGlass {
            if #available(watchOS 26.0, *) {
                icon.glassEffect(.clear, in: Circle())
            } else {
                composerActionFallback(icon)
            }
        } else {
            composerActionFallback(icon)
        }
    }

    @ViewBuilder
    private func composerActionFallback<Content: View>(_ content: Content) -> some View {
        content
            .background(Circle().fill(inputFillColor))
            .overlay(Circle().stroke(inputStrokeColor, lineWidth: 0.8))
    }

    private var inputFillColor: Color {
        configuration.enableBackground ? Color.black.opacity(0.3) : Color(white: 0.3)
    }

    private var inputStrokeColor: Color {
        configuration.prefersDarkAppearance
            ? Color.white.opacity(0.35)
            : Color.black.opacity(0.12)
    }
}

@MainActor
private struct WatchChatTranscriptBubbleRow: View {
    let row: WatchChatTranscriptRenderRow
    let configuration: WatchChatTranscriptImageConfiguration
    let providers: [Provider]

    var body: some View {
        ChatBubble(
            messageState: row.messageState,
            preparedMarkdownPayload: row.preparedMarkdownPayload,
            preparedReasoningMarkdownPayload: row.preparedReasoningMarkdownPayload,
            reasoningThinkingTitle: row.reasoningThinkingTitle,
            reasoningPreviewMaxHeight: 64.5,
            isReasoningExpanded: .constant(true),
            isReasoningAutoPreview: false,
            isToolCallsExpanded: .constant(false),
            enableMarkdown: configuration.enableMarkdown,
            enableBackground: configuration.enableBackground,
            enableLiquidGlass: configuration.enableLiquidGlass,
            enableNoBubbleUI: configuration.enableNoBubbleUI,
            enableAdvancedRenderer: configuration.enableAdvancedRenderer,
            enableExperimentalToolResultDisplay: true,
            enableMathRendering: false,
            showsStreamingIndicators: false,
            mergeWithPrevious: row.mergeWithPrevious,
            mergeWithNext: row.mergeWithNext,
            messageActionBarContinuesToNext: row.messageActionBarContinuesToNext,
            connectsTimelineFromPrevious: row.connectsTimelineFromPrevious,
            connectsTimelineToNext: row.connectsTimelineToNext,
            hasAutoOpenedPendingToolCall: { _ in true },
            markPendingToolCallAutoOpened: { _ in },
            onCodeBlockHeaderTap: nil,
            responseAttemptVersionInfo: row.responseAttemptVersionInfo,
            canRetry: row.canRetry,
            onRetry: {},
            onCopy: {},
            onSwitchToPreviousVersion: {},
            onSwitchToNextVersion: {},
            isSelectionMode: false,
            isSelected: false,
            onToggleSelection: {},
            onOpenMore: nil,
            providers: providers
        )
        .id(row.id)
        .allowsHitTesting(false)
    }
}

private struct WatchChatTranscriptRepeatedBackground: View {
    let image: UIImage?
    let configuration: WatchChatTranscriptImageConfiguration

    var body: some View {
        ZStack {
            backgroundBaseColor

            if let image, configuration.enableBackground {
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    drawRepeatedBackground(image, in: &context, size: size)
                }
                .blur(radius: CGFloat(max(0, configuration.backgroundBlurRadius)))
            }
        }
    }

    private var backgroundBaseColor: Color {
        guard configuration.backgroundContentMode == .fit,
              configuration.enableBackground,
              image != nil else {
            return .black
        }
        return configuration.prefersDarkAppearance ? .black : Color(white: 0.95)
    }

    private func drawRepeatedBackground(
        _ image: UIImage,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let tileHeight = max(configuration.backgroundTileHeight, 1)
        let canvasBounds = CGRect(origin: .zero, size: size)
        let resolvedImage = context.resolve(Image(uiImage: image))
        context.opacity = min(max(configuration.backgroundOpacity, 0), 1)

        var originY: CGFloat = 0
        while originY < size.height {
            let fullTile = CGRect(x: 0, y: originY, width: size.width, height: tileHeight)
            let visibleTile = fullTile.intersection(canvasBounds)
            let destination = destinationRect(
                imageSize: image.size,
                tileRect: fullTile,
                contentMode: configuration.backgroundContentMode
            )
            context.drawLayer { layer in
                layer.clip(to: Path(visibleTile))
                layer.draw(resolvedImage, in: destination)
            }
            originY += tileHeight
        }
    }

    private func destinationRect(
        imageSize: CGSize,
        tileRect: CGRect,
        contentMode: WatchChatTranscriptImageConfiguration.BackgroundContentMode
    ) -> CGRect {
        let sourceWidth = max(imageSize.width, 1)
        let sourceHeight = max(imageSize.height, 1)
        let widthScale = tileRect.width / sourceWidth
        let heightScale = tileRect.height / sourceHeight
        let scale = contentMode == .fill
            ? max(widthScale, heightScale)
            : min(widthScale, heightScale)
        let destinationSize = CGSize(width: sourceWidth * scale, height: sourceHeight * scale)
        return CGRect(
            x: tileRect.midX - destinationSize.width / 2,
            y: tileRect.midY - destinationSize.height / 2,
            width: destinationSize.width,
            height: destinationSize.height
        )
    }
}
