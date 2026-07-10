// ============================================================================
// ChatTranscriptImageRenderer.swift
// ============================================================================
// 聊天长图导出渲染器
// - 在后台使用 Core Graphics 绘制，避免把长会话排版工作放进 SwiftUI 渲染链路
// - 还原标题栏、循环聊天背景、消息气泡和底部输入栏
// ============================================================================

import CoreGraphics
#if canImport(CoreImage)
import CoreImage
#endif
import CoreText
import Foundation
import ImageIO
#if canImport(AVFoundation) && !os(watchOS)
import AVFoundation
#endif

struct ChatTranscriptImageRenderer {
    private let canvasWidth: CGFloat = 430
    private let headerHeight: CGFloat = 76
    private let composerHeight: CGFloat = 76
    private let horizontalMargin: CGFloat = 14
    private let bubblePadding: CGFloat = 12
    private let sectionSpacing: CGFloat = 8
    private let maximumPixelHeight: CGFloat = 50_000
    #if os(watchOS)
    private let maximumBitmapBytes: CGFloat = 40 * 1_024 * 1_024
    #else
    private let maximumBitmapBytes: CGFloat = 128 * 1_024 * 1_024
    #endif
    #if canImport(CoreImage)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    #endif

    func render(
        session: ChatSession?,
        messages: [ChatMessage],
        includeReasoning: Bool,
        style: ChatTranscriptImageStyle
    ) throws -> Data {
        let visibleMessages = messages.filter { $0.role != .system }
        guard !visibleMessages.isEmpty else {
            throw ChatTranscriptExportError.emptyMessages
        }

        let theme = Theme(style: style)
        let layouts = try visibleMessages.map {
            try makeMessageLayout(message: $0, includeReasoning: includeReasoning, style: style)
        }
        let positioned = position(layouts)
        guard let last = positioned.last else {
            throw ChatTranscriptExportError.emptyMessages
        }

        let composerOriginY = last.rect.maxY + 18
        let totalHeight = composerOriginY + composerHeight
        let scale = try outputScale(for: totalHeight)
        let pixelWidth = Int(ceil(canvasWidth * scale))
        let pixelHeight = Int(ceil(totalHeight * scale))

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ChatTranscriptExportError.imageRenderFailed
        }

        // 将 Quartz 的左下角坐标系转换为更适合界面排版的左上角坐标系。
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.interpolationQuality = .high
        context.setAllowsAntialiasing(true)

        let backgroundImage = loadBackgroundImage(style: style)
        drawBackground(
            in: context,
            height: totalHeight,
            image: backgroundImage,
            style: style,
            theme: theme
        )
        drawHeader(in: context, session: session, style: style, theme: theme)

        for item in positioned {
            try Task.checkCancellation()
            drawMessage(item.layout, in: item.rect, context: context, style: style, theme: theme)
        }

        drawComposer(in: context, originY: composerOriginY, style: style, theme: theme)

        guard let image = context.makeImage() else {
            throw ChatTranscriptExportError.imageRenderFailed
        }
        return try pngData(from: image)
    }

    private func makeMessageLayout(
        message: ChatMessage,
        includeReasoning: Bool,
        style: ChatTranscriptImageStyle
    ) throws -> MessageLayout {
        try Task.checkCancellation()

        let isOutgoing = message.role == .user
        let isError = message.role == .error
        let usesNoBubble = style.usesNoBubbleStyle && !isOutgoing && !isError
        let maximumWidth: CGFloat = usesNoBubble ? canvasWidth - horizontalMargin * 2 : (isOutgoing ? 326 : 360)
        let contentMaximumWidth = maximumWidth - bubblePadding * 2

        let imageAttachments = (message.imageFileNames ?? []).map { fileName in
            ImageAttachmentLayout(
                fileName: fileName,
                image: loadStoredImage(named: fileName),
                size: .zero
            )
        }
        let hasImages = !imageAttachments.isEmpty
        let content = visibleText(message.content, hidesImagePlaceholder: hasImages)
        let reasoning = includeReasoning ? visibleText(message.reasoningContent ?? "") : ""
        let tools = (message.toolCalls ?? []).map(makeToolSummary)
        let files = (message.fileFileNames ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let audioFileName = message.audioFileName?.trimmingCharacters(in: .whitespacesAndNewlines)

        let bodyFont = FontSpec(size: 16)
        let contentMeasurement = measureText(content, width: contentMaximumWidth, font: bodyFont)
        let reasoningMeasurement = measureText(reasoning, width: contentMaximumWidth - 20, font: FontSpec(size: 13))
        let toolMeasurements = tools.map {
            measureText($0.detail, width: contentMaximumWidth - 20, font: FontSpec(size: 12))
        }

        var requiredContentWidth = max(contentMeasurement.width, reasoningMeasurement.width + 20)
        for (index, tool) in tools.enumerated() {
            let titleSize = measureText(tool.name, width: contentMaximumWidth - 20, font: FontSpec(size: 13, isBold: true))
            requiredContentWidth = max(requiredContentWidth, titleSize.width + 20, toolMeasurements[index].width + 20)
        }
        if hasImages {
            requiredContentWidth = max(requiredContentWidth, min(272, contentMaximumWidth))
        }
        if !files.isEmpty || audioFileName?.isEmpty == false {
            requiredContentWidth = max(requiredContentWidth, min(238, contentMaximumWidth))
        }

        let minimumWidth: CGFloat = usesNoBubble ? maximumWidth : 76
        let bubbleWidth = usesNoBubble
            ? maximumWidth
            : min(maximumWidth, max(minimumWidth, ceil(requiredContentWidth + bubblePadding * 2)))
        let innerWidth = bubbleWidth - bubblePadding * 2

        let finalContentMeasurement = measureText(content, width: innerWidth, font: bodyFont)
        let finalReasoningMeasurement = measureText(reasoning, width: innerWidth - 20, font: FontSpec(size: 13))
        let finalToolMeasurements = tools.map {
            measureText($0.detail, width: innerWidth - 20, font: FontSpec(size: 12))
        }
        let attachmentWidth = min(innerWidth, 272)
        let finalImages = imageAttachments.map { attachment -> ImageAttachmentLayout in
            let aspectRatio: CGFloat
            if let image = attachment.image, image.height > 0 {
                aspectRatio = CGFloat(image.width) / CGFloat(image.height)
            } else {
                aspectRatio = 4 / 3
            }
            let height = min(220, max(112, attachmentWidth / min(max(aspectRatio, 0.65), 1.8)))
            return ImageAttachmentLayout(
                fileName: attachment.fileName,
                image: attachment.image,
                size: CGSize(width: attachmentWidth, height: height)
            )
        }

        var sectionHeights: [CGFloat] = []
        if !content.isEmpty {
            sectionHeights.append(finalContentMeasurement.height)
        }
        if !reasoning.isEmpty {
            sectionHeights.append(24 + finalReasoningMeasurement.height + 16)
        }
        for measurement in finalToolMeasurements {
            sectionHeights.append(30 + measurement.height + 16)
        }
        sectionHeights.append(contentsOf: files.map { _ in 38 })
        if audioFileName?.isEmpty == false {
            sectionHeights.append(42)
        }
        sectionHeights.append(contentsOf: finalImages.map(\.size.height))

        let contentHeight = sectionHeights.reduce(0, +)
            + CGFloat(max(0, sectionHeights.count - 1)) * sectionSpacing
        let bubbleHeight = max(44, contentHeight + bubblePadding * 2)

        return MessageLayout(
            message: message,
            content: content,
            reasoning: reasoning,
            tools: tools,
            files: files,
            audioFileName: audioFileName?.isEmpty == false ? audioFileName : nil,
            images: finalImages,
            contentHeight: finalContentMeasurement.height,
            reasoningHeight: finalReasoningMeasurement.height,
            toolDetailHeights: finalToolMeasurements.map(\.height),
            size: CGSize(width: bubbleWidth, height: bubbleHeight),
            isOutgoing: isOutgoing,
            isError: isError,
            usesNoBubble: usesNoBubble
        )
    }

    private func position(_ layouts: [MessageLayout]) -> [PositionedMessage] {
        var positioned: [PositionedMessage] = []
        positioned.reserveCapacity(layouts.count)
        var y = headerHeight + 18

        for (index, layout) in layouts.enumerated() {
            if index > 0 {
                let previous = layouts[index - 1]
                y += previous.message.role == layout.message.role ? 4 : 10
            }
            let x: CGFloat
            if layout.usesNoBubble {
                x = (canvasWidth - layout.size.width) / 2
            } else if layout.isOutgoing {
                x = canvasWidth - horizontalMargin - layout.size.width
            } else {
                x = horizontalMargin
            }
            let rect = CGRect(origin: CGPoint(x: x, y: y), size: layout.size)
            positioned.append(PositionedMessage(layout: layout, rect: rect))
            y = rect.maxY
        }
        return positioned
    }

    private func outputScale(for designHeight: CGFloat) throws -> CGFloat {
        for scale: CGFloat in [2, 1] {
            let pixelWidth = ceil(canvasWidth * scale)
            let pixelHeight = ceil(designHeight * scale)
            let bytes = pixelWidth * pixelHeight * 4
            if pixelHeight <= maximumPixelHeight && bytes <= maximumBitmapBytes {
                return scale
            }
        }
        throw ChatTranscriptExportError.imageTooLong
    }

    private func drawBackground(
        in context: CGContext,
        height: CGFloat,
        image: CGImage?,
        style: ChatTranscriptImageStyle,
        theme: Theme
    ) {
        let fullRect = CGRect(x: 0, y: 0, width: canvasWidth, height: height)
        context.setFillColor(theme.baseBackground)
        context.fill(fullRect)

        let tileHeight = max(640, canvasWidth * 1.86)
        var tileOriginY: CGFloat = 0
        while tileOriginY < height {
            let tileRect = CGRect(
                x: 0,
                y: tileOriginY,
                width: canvasWidth,
                height: min(tileHeight, height - tileOriginY)
            )
            if style.usesCustomBackground, let image {
                drawBackgroundImage(image, in: tileRect, context: context, style: style, theme: theme)
            } else {
                drawDefaultBackground(in: tileRect, context: context, theme: theme)
            }
            tileOriginY += tileHeight
        }
    }

    private func drawDefaultBackground(in rect: CGRect, context: CGContext, theme: Theme) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [theme.backgroundGradientStart, theme.backgroundGradientEnd] as CFArray,
            locations: [0, 1]
        ) else { return }
        context.saveGState()
        context.addRect(rect)
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY),
            options: []
        )

        context.setStrokeColor(theme.patternColor)
        context.setLineWidth(1.2)
        let patternSize: CGFloat = 60
        for row in stride(from: rect.minY, through: rect.maxY + patternSize, by: patternSize) {
            let rowIndex = Int((row - rect.minY) / patternSize)
            let offset: CGFloat = rowIndex.isMultiple(of: 2) ? 0 : patternSize / 2
            for column in stride(from: -patternSize, through: canvasWidth + patternSize, by: patternSize) {
                let center = CGPoint(x: column + offset, y: row)
                let selector = abs(Int(column + row)) % 3
                switch selector {
                case 0:
                    context.strokeEllipse(in: CGRect(x: center.x - 6, y: center.y - 5, width: 12, height: 9))
                    context.move(to: CGPoint(x: center.x - 1, y: center.y + 4))
                    context.addLine(to: CGPoint(x: center.x - 5, y: center.y + 9))
                    context.strokePath()
                case 1:
                    drawStar(center: center, radius: 6, context: context)
                default:
                    context.move(to: CGPoint(x: center.x - 7, y: center.y + 5))
                    context.addLine(to: CGPoint(x: center.x + 7, y: center.y))
                    context.addLine(to: CGPoint(x: center.x - 7, y: center.y - 5))
                    context.closePath()
                    context.strokePath()
                }
            }
        }
        context.restoreGState()
    }

    private func drawBackgroundImage(
        _ image: CGImage,
        in rect: CGRect,
        context: CGContext,
        style: ChatTranscriptImageStyle,
        theme: Theme
    ) {
        context.saveGState()
        context.addRect(rect)
        context.clip()
        context.setFillColor(theme.baseBackground)
        context.fill(rect)
        context.setAlpha(CGFloat(style.backgroundOpacity))

        let sourceSize = CGSize(width: image.width, height: image.height)
        let widthScale = rect.width / max(sourceSize.width, 1)
        let heightScale = rect.height / max(sourceSize.height, 1)
        let scale = style.backgroundContentMode == .fill
            ? max(widthScale, heightScale)
            : min(widthScale, heightScale)
        let destinationSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let destination = CGRect(
            x: rect.midX - destinationSize.width / 2,
            y: rect.midY - destinationSize.height / 2,
            width: destinationSize.width,
            height: destinationSize.height
        )
        drawImage(image, in: destination, context: context)
        context.restoreGState()
    }

    private func drawHeader(
        in context: CGContext,
        session: ChatSession?,
        style: ChatTranscriptImageStyle,
        theme: Theme
    ) {
        let rect = CGRect(x: 0, y: 0, width: canvasWidth, height: headerHeight)
        context.saveGState()
        context.setFillColor(theme.chrome)
        context.fill(rect)
        context.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: theme.shadow)

        let leftButton = CGRect(x: 16, y: 16, width: 44, height: 44)
        let rightButton = CGRect(x: canvasWidth - 60, y: 16, width: 44, height: 44)
        let titlePill = CGRect(x: 78, y: 11, width: canvasWidth - 156, height: 54)
        fillRoundedRect(leftButton, radius: 22, color: theme.controlFill, context: context)
        fillRoundedRect(rightButton, radius: 22, color: theme.controlFill, context: context)
        fillRoundedRect(titlePill, radius: 27, color: theme.controlFill, context: context)
        context.restoreGState()

        context.setStrokeColor(theme.chromeForeground)
        context.setLineWidth(2)
        for offset in [-6, 0, 6] as [CGFloat] {
            context.move(to: CGPoint(x: leftButton.midX - 8, y: leftButton.midY + offset))
            context.addLine(to: CGPoint(x: leftButton.midX + 8, y: leftButton.midY + offset))
            context.strokePath()
        }
        drawSettingsIcon(center: CGPoint(x: rightButton.midX, y: rightButton.midY), context: context, color: theme.chromeForeground)

        let rawTitle = session?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle?.isEmpty == false ? rawTitle! : style.untitledConversationName
        drawCenteredText(
            title,
            in: CGRect(x: titlePill.minX + 18, y: titlePill.minY + 4, width: titlePill.width - 36, height: 28),
            font: FontSpec(size: 16, isBold: true),
            color: theme.chromeForeground,
            context: context
        )
        drawCenteredText(
            style.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? style.subtitle!
                : "ETOS LLM Studio",
            in: CGRect(x: titlePill.minX + 18, y: titlePill.minY + 32, width: titlePill.width - 36, height: 18),
            font: FontSpec(size: 11),
            color: theme.chromeSecondary,
            context: context
        )

        context.setStrokeColor(theme.chromeSecondary)
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: titlePill.maxX - 16, y: titlePill.midY - 2))
        context.addLine(to: CGPoint(x: titlePill.maxX - 12, y: titlePill.midY + 2))
        context.addLine(to: CGPoint(x: titlePill.maxX - 8, y: titlePill.midY - 2))
        context.strokePath()
    }

    private func drawMessage(
        _ layout: MessageLayout,
        in rect: CGRect,
        context: CGContext,
        style: ChatTranscriptImageStyle,
        theme: Theme
    ) {
        if !layout.usesNoBubble {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: theme.shadow)
            if layout.isError {
                fillRoundedRect(rect, radius: 18, color: theme.errorBubble, context: context)
            } else if layout.isOutgoing {
                fillRoundedGradient(
                    rect,
                    radius: 18,
                    startColor: theme.userBubbleStart,
                    endColor: theme.userBubbleEnd,
                    context: context
                )
            } else {
                fillRoundedRect(rect, radius: 18, color: theme.assistantBubble, context: context)
            }
            context.restoreGState()
        }

        let foreground: CGColor
        if layout.isError {
            foreground = theme.errorText
        } else if layout.isOutgoing {
            foreground = theme.userText
        } else {
            foreground = theme.assistantText
        }
        let secondary = foreground.copy(alpha: 0.72) ?? foreground
        let cardFill = layout.isOutgoing
            ? (CGColor(gray: 1, alpha: 0.16))
            : (style.prefersDarkAppearance ? CGColor(gray: 1, alpha: 0.09) : CGColor(gray: 0, alpha: 0.06))

        var cursorY = rect.minY + bubblePadding
        var didDrawSection = false

        func advanceBeforeSection() {
            if didDrawSection {
                cursorY += sectionSpacing
            }
            didDrawSection = true
        }

        func drawImages() {
            for attachment in layout.images {
                advanceBeforeSection()
                let imageRect = CGRect(
                    x: rect.minX + bubblePadding,
                    y: cursorY,
                    width: attachment.size.width,
                    height: attachment.size.height
                )
                if let image = attachment.image {
                    context.saveGState()
                    context.addPath(CGPath(roundedRect: imageRect, cornerWidth: 12, cornerHeight: 12, transform: nil))
                    context.clip()
                    drawAspectFillImage(image, in: imageRect, context: context)
                    context.restoreGState()
                } else {
                    fillRoundedRect(imageRect, radius: 12, color: cardFill, context: context)
                    drawPhotoPlaceholder(in: imageRect, color: secondary, context: context)
                }
                cursorY = imageRect.maxY
            }
        }

        if layout.isOutgoing {
            drawImages()
        }

        for fileName in layout.files {
            advanceBeforeSection()
            let card = CGRect(x: rect.minX + bubblePadding, y: cursorY, width: rect.width - bubblePadding * 2, height: 38)
            fillRoundedRect(card, radius: 12, color: cardFill, context: context)
            drawDocumentIcon(in: CGRect(x: card.minX + 10, y: card.minY + 9, width: 18, height: 20), color: secondary, context: context)
            drawText(
                fileName,
                in: CGRect(x: card.minX + 36, y: card.minY + 9, width: card.width - 46, height: 20),
                font: FontSpec(size: 13, isBold: true),
                color: foreground,
                context: context
            )
            cursorY = card.maxY
        }

        if !layout.content.isEmpty {
            advanceBeforeSection()
            let textRect = CGRect(
                x: rect.minX + bubblePadding,
                y: cursorY,
                width: rect.width - bubblePadding * 2,
                height: layout.contentHeight
            )
            drawText(layout.content, in: textRect, font: FontSpec(size: 16), color: foreground, context: context)
            cursorY = textRect.maxY
        }

        if !layout.reasoning.isEmpty {
            advanceBeforeSection()
            let panel = CGRect(
                x: rect.minX + bubblePadding,
                y: cursorY,
                width: rect.width - bubblePadding * 2,
                height: 24 + layout.reasoningHeight + 16
            )
            fillRoundedRect(panel, radius: 12, color: cardFill, context: context)
            drawText(
                NSLocalizedString("思考", comment: "聊天长图中的思考区标题"),
                in: CGRect(x: panel.minX + 10, y: panel.minY + 8, width: panel.width - 20, height: 18),
                font: FontSpec(size: 12, isBold: true),
                color: secondary,
                context: context
            )
            drawText(
                layout.reasoning,
                in: CGRect(x: panel.minX + 10, y: panel.minY + 30, width: panel.width - 20, height: layout.reasoningHeight),
                font: FontSpec(size: 13),
                color: foreground,
                context: context
            )
            cursorY = panel.maxY
        }

        for (index, tool) in layout.tools.enumerated() {
            advanceBeforeSection()
            let panel = CGRect(
                x: rect.minX + bubblePadding,
                y: cursorY,
                width: rect.width - bubblePadding * 2,
                height: 30 + layout.toolDetailHeights[index] + 16
            )
            fillRoundedRect(panel, radius: 12, color: cardFill, context: context)
            drawToolIcon(in: CGRect(x: panel.minX + 10, y: panel.minY + 9, width: 16, height: 16), color: secondary, context: context)
            drawText(
                tool.name,
                in: CGRect(x: panel.minX + 32, y: panel.minY + 8, width: panel.width - 42, height: 18),
                font: FontSpec(size: 13, isBold: true),
                color: foreground,
                context: context
            )
            drawText(
                tool.detail,
                in: CGRect(x: panel.minX + 10, y: panel.minY + 32, width: panel.width - 20, height: layout.toolDetailHeights[index]),
                font: FontSpec(size: 12),
                color: secondary,
                context: context
            )
            cursorY = panel.maxY
        }

        if let audioFileName = layout.audioFileName {
            advanceBeforeSection()
            let card = CGRect(x: rect.minX + bubblePadding, y: cursorY, width: rect.width - bubblePadding * 2, height: 42)
            fillRoundedRect(card, radius: 14, color: cardFill, context: context)
            drawWaveform(in: CGRect(x: card.minX + 10, y: card.minY + 10, width: 26, height: 22), color: secondary, context: context)
            drawText(
                audioFileName,
                in: CGRect(x: card.minX + 44, y: card.minY + 11, width: card.width - 54, height: 20),
                font: FontSpec(size: 13, isBold: true),
                color: foreground,
                context: context
            )
            cursorY = card.maxY
        }

        if !layout.isOutgoing {
            drawImages()
        }
    }

    private func drawComposer(
        in context: CGContext,
        originY: CGFloat,
        style: ChatTranscriptImageStyle,
        theme: Theme
    ) {
        let barRect = CGRect(x: 0, y: originY, width: canvasWidth, height: composerHeight)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: theme.shadow)
        context.setFillColor(theme.chrome)
        context.fill(barRect)
        context.restoreGState()

        let attachmentButton = CGRect(x: 16, y: originY + 18, width: 40, height: 40)
        let actionButton = CGRect(x: canvasWidth - 56, y: originY + 18, width: 40, height: 40)
        let inputField = CGRect(x: 68, y: originY + 18, width: canvasWidth - 136, height: 40)
        fillRoundedRect(attachmentButton, radius: 20, color: theme.controlFill, context: context)
        fillRoundedRect(inputField, radius: 20, color: theme.controlFill, context: context)
        fillRoundedRect(actionButton, radius: 20, color: theme.actionFill, context: context)

        drawPaperclip(center: CGPoint(x: attachmentButton.midX, y: attachmentButton.midY), color: theme.actionFill, context: context)
        drawText(
            style.inputPlaceholder,
            in: CGRect(x: inputField.minX + 14, y: inputField.minY + 10, width: inputField.width - 28, height: 20),
            font: FontSpec(size: 15),
            color: theme.chromeSecondary,
            context: context
        )
        drawMicrophone(center: CGPoint(x: actionButton.midX, y: actionButton.midY), color: CGColor(gray: 1, alpha: 1), context: context)
    }

    private func loadBackgroundImage(style: ChatTranscriptImageStyle) -> CGImage? {
        guard style.usesCustomBackground, let url = style.backgroundMediaURL else { return nil }
        let image: CGImage?
        if ConfigLoader.isVideoBackgroundFile(url.lastPathComponent) {
            #if canImport(AVFoundation) && !os(watchOS)
            image = loadVideoFrame(from: url)
            #else
            image = nil
            #endif
        } else {
            image = loadImage(at: url)
        }
        guard let image else { return nil }
        return blurredImage(image, radius: style.backgroundBlurRadius) ?? image
    }

    private func loadStoredImage(named fileName: String) -> CGImage? {
        let url = Persistence.getImageDirectory().appendingPathComponent(fileName)
        return loadImage(at: url)
    }

    private func loadImage(at url: URL) -> CGImage? {
        #if canImport(CoreImage)
        guard let input = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              !input.extent.isEmpty,
              input.extent.isFinite else {
            return nil
        }
        return ciContext.createCGImage(input, from: input.extent)
        #else
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4_096
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        #endif
    }

    private func blurredImage(_ image: CGImage, radius: Double) -> CGImage? {
        guard radius > 0.01 else { return image }
        #if canImport(CoreImage)
        let input = CIImage(cgImage: image)
        let output = input
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent)
        return ciContext.createCGImage(output, from: input.extent)
        #else
        return image
        #endif
    }

    #if canImport(AVFoundation) && !os(watchOS)
    private func loadVideoFrame(from url: URL) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_290, height: 2_796)

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var generatedImage: CGImage?
        let previewTime = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: previewTime)]) { _, image, _, _, _ in
            lock.lock()
            generatedImage = image
            lock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            generator.cancelAllCGImageGeneration()
            return nil
        }
        lock.lock()
        let result = generatedImage
        lock.unlock()
        return result
    }
    #endif

    private func makeToolSummary(_ call: InternalToolCall) -> ToolSummary {
        let name = call.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolSummary(
            name: name.isEmpty ? NSLocalizedString("工具调用", comment: "聊天长图中的工具卡片标题") : name,
            // 长图固定使用折叠态摘要，避免导出聊天界面未展开的参数或结果。
            detail: NSLocalizedString("工具调用", comment: "聊天长图中的工具卡片状态")
        )
    }

    private func visibleText(_ raw: String, hidesImagePlaceholder: Bool = false) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if hidesImagePlaceholder, ["[图片]", "[圖片]", "[Image]", "[画像]"].contains(trimmed) {
            return ""
        }

        let inlineText: String
        if let attributed = try? AttributedString(
            markdown: trimmed,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            inlineText = String(attributed.characters)
        } else {
            inlineText = trimmed
        }

        var isInsideCodeFence = false
        let cleanedLines = inlineText.components(separatedBy: .newlines).compactMap { line -> String? in
            let whitespaceTrimmed = line.trimmingCharacters(in: .whitespaces)
            if whitespaceTrimmed.hasPrefix("```") || whitespaceTrimmed.hasPrefix("~~~") {
                isInsideCodeFence.toggle()
                return nil
            }
            if isInsideCodeFence {
                return line
            }
            var cleaned = line
            while cleaned.hasPrefix("#") {
                cleaned.removeFirst()
            }
            if cleaned.hasPrefix(" ") {
                cleaned.removeFirst()
            }
            if cleaned.hasPrefix("> ") {
                cleaned.removeFirst(2)
            }
            return cleaned
        }
        return cleanedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func measureText(_ text: String, width: CGFloat, font: FontSpec) -> CGSize {
        guard !text.isEmpty, width > 0 else { return .zero }
        let attributed = makeAttributedString(text, font: font, color: CGColor(gray: 0, alpha: 1))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        return CGSize(width: min(width, ceil(suggested.width)), height: max(font.size + 3, ceil(suggested.height)))
    }

    private func drawText(
        _ text: String,
        in rect: CGRect,
        font: FontSpec,
        color: CGColor,
        context: CGContext
    ) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let attributed = makeAttributedString(text, font: font, color: color)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: rect.minY + rect.height)
        context.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func drawCenteredText(
        _ text: String,
        in rect: CGRect,
        font: FontSpec,
        color: CGColor,
        context: CGContext
    ) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let attributed = makeAttributedString(text, font: font, color: color)
        let sourceLine = CTLineCreateWithAttributedString(attributed)
        let token = CTLineCreateWithAttributedString(makeAttributedString("…", font: font, color: color))
        let line = CTLineCreateTruncatedLine(sourceLine, Double(rect.width), .end, token) ?? sourceLine
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let lineWidth = min(rect.width, CTLineGetBoundsWithOptions(line, .useOpticalBounds).width)
        let baseline = max(descent, (rect.height - ascent - descent) / 2 + descent)

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: rect.midX - lineWidth / 2, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func makeAttributedString(_ text: String, font: FontSpec, color: CGColor) -> NSAttributedString {
        let fontName = font.isBold ? "Helvetica-Bold" : "Helvetica"
        let coreTextFont = CTFontCreateWithName(fontName as CFString, font.size, nil)
        return NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): coreTextFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]
        )
    }

    private func fillRoundedRect(_ rect: CGRect, radius: CGFloat, color: CGColor, context: CGContext) {
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    private func fillRoundedGradient(
        _ rect: CGRect,
        radius: CGFloat,
        startColor: CGColor,
        endColor: CGColor,
        context: CGContext
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [startColor, endColor] as CFArray,
            locations: [0, 1]
        ) else { return }
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.minY),
            end: CGPoint(x: rect.maxX, y: rect.maxY),
            options: []
        )
        context.restoreGState()
    }

    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: rect.minY + rect.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    private func drawAspectFillImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let sourceSize = CGSize(width: image.width, height: image.height)
        let scale = max(rect.width / max(sourceSize.width, 1), rect.height / max(sourceSize.height, 1))
        let destinationSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let destination = CGRect(
            x: rect.midX - destinationSize.width / 2,
            y: rect.midY - destinationSize.height / 2,
            width: destinationSize.width,
            height: destinationSize.height
        )
        drawImage(image, in: destination, context: context)
    }

    private func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ChatTranscriptExportError.imageRenderFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ChatTranscriptExportError.imageRenderFailed
        }
        return data as Data
    }

}
