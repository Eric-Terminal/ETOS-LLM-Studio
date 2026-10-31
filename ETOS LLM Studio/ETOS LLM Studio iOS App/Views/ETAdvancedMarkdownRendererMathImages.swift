// ============================================================================
// ETAdvancedMarkdownRendererMathImages.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 iOS Markdown 数学公式图片提供、缓存与 SwiftMath 渲染。
// ============================================================================

import Foundation
import SwiftUI
import MarkdownUI
import UIKit

#if canImport(SwiftMath)
import SwiftMath
#endif

struct ETIOSMarkdownImageProvider: ImageProvider {
    let textColor: ETIOSMathColorComponents
    let fontScale: Double

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let request = ETNativeMathMarkdownCodec.request(from: url) {
            ETIOSMathBlockImageView(
                request: request,
                textColor: textColor,
                fontScale: fontScale
            )
        } else {
            DefaultImageProvider.default.makeImage(url: url)
        }
    }
}

struct ETIOSMarkdownInlineImageProvider: InlineImageProvider {
    let textColor: ETIOSMathColorComponents
    let fontScale: Double

    func image(with url: URL, label: String) async throws -> Image {
        guard let request = ETNativeMathMarkdownCodec.request(from: url) else {
            return try await DefaultInlineImageProvider.default.image(with: url, label: label)
        }

        guard let renderedImage = await ETIOSMathImageRenderer.image(for: request, textColor: textColor, fontScale: fontScale) else {
            return Image(systemName: "function")
        }

        return Image(uiImage: renderedImage.image)
    }
}

private struct ETIOSMathBlockImageView: View {
    let request: ETNativeMathMarkdownCodec.Request
    let textColor: ETIOSMathColorComponents
    let fontScale: Double

    @State private var renderedImage: ETIOSRenderedMathImage?
    @State private var didAttemptRender = false

    var body: some View {
        Group {
            if let renderedImage {
                ScrollView(.horizontal, showsIndicators: false) {
                    Image(uiImage: renderedImage.image)
                        .interpolation(.high)
                        .antialiased(true)
                }
            } else if didAttemptRender {
                Text(verbatim: request.latex)
                    .font(.system(size: request.renderKind.fallbackFontSize(fontScale: fontScale), design: .serif))
                    .foregroundStyle(textColor.swiftUIColor.opacity(0.9))
                    .textSelection(.enabled)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(textColor.swiftUIColor.opacity(0.08))
                    .frame(height: request.renderKind.placeholderHeight(fontScale: fontScale))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(request.latex)
        .task(id: taskKey) {
            didAttemptRender = false
            renderedImage = nil
            let preparedImage = await ETIOSMathImageRenderer.image(for: request, textColor: textColor, fontScale: fontScale)
            guard !Task.isCancelled else { return }
            renderedImage = preparedImage
            didAttemptRender = true
        }
    }

    private var taskKey: String {
        "\(request.renderKind.rawValue)|\(request.latex)|\(textColor.cacheKey)|\(fontScale)"
    }
}

struct ETIOSMathColorComponents: Hashable, Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(_ color: Color) {
        let resolvedColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        if resolvedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        } else {
            self.red = 0
            self.green = 0
            self.blue = 0
            self.alpha = 1
        }
    }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var swiftUIColor: Color {
        Color(uiColor: uiColor)
    }

    var cacheKey: String {
        "\(red)|\(green)|\(blue)|\(alpha)"
    }
}

/// 只传递已经完成的不可变图片，保留渲染器的像素比例，避免在另一块显示器上按新比例重解码。
final class ETIOSRenderedMathImage: @unchecked Sendable {
    let image: UIImage

    init(image: UIImage) {
        self.image = image
    }
}

enum ETIOSMathImageRenderer {
#if canImport(SwiftMath)
    private static let cache = NSCache<NSString, ETIOSRenderedMathImage>()
    // SwiftMath 共享字体及排版缓存；整个渲染操作必须串行，且不能占用主线程。
    private static let renderQueue = DispatchQueue(label: "com.ericterminal.els.math-render", qos: .userInitiated)

    static func image(
        for request: ETNativeMathMarkdownCodec.Request,
        textColor: ETIOSMathColorComponents,
        fontScale: Double
    ) async -> ETIOSRenderedMathImage? {
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<ETIOSRenderedMathImage?, Never>) in
            renderQueue.async {
                let cacheKey = "\(request.renderKind.rawValue)|\(request.latex)|\(textColor.cacheKey)|\(fontScale)" as NSString
                // 队列内复查，使并发请求同一公式时只实际渲染一次。
                if let cachedImage = cache.object(forKey: cacheKey) {
                    continuation.resume(returning: cachedImage)
                    return
                }
                let image = MTMathImage(
                    latex: request.latex,
                    fontSize: request.renderKind.fontSize(fontScale: fontScale),
                    textColor: textColor.uiColor,
                    labelMode: request.renderKind.labelMode,
                    textAlignment: .left
                )
                image.contentInsets = UIEdgeInsets(top: 1, left: 0, bottom: 1, right: 0)
                let result = image.asImage()
                guard result.0 == nil, let renderedImage = result.1 else {
                    continuation.resume(returning: nil)
                    return
                }
                let preparedImage = ETIOSRenderedMathImage(image: renderedImage)
                cache.setObject(preparedImage, forKey: cacheKey)
                continuation.resume(returning: preparedImage)
            }
        }
    }
#else
    static func image(
        for request: ETNativeMathMarkdownCodec.Request,
        textColor: ETIOSMathColorComponents,
        fontScale: Double
    ) async -> ETIOSRenderedMathImage? {
        _ = request
        _ = textColor
        _ = fontScale
        return nil
    }
#endif
}
