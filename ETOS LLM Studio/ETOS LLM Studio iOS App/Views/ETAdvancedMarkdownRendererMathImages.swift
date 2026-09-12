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

        guard let data = await ETIOSMathImageRenderer.imageData(for: request, textColor: textColor, fontScale: fontScale),
              let image = UIImage(data: data, scale: UIScreen.main.scale) else {
            return Image(systemName: "function")
        }

        return Image(uiImage: image)
    }
}

private struct ETIOSMathBlockImageView: View {
    let request: ETNativeMathMarkdownCodec.Request
    let textColor: ETIOSMathColorComponents
    let fontScale: Double

    @State private var renderedImageData: Data?
    @State private var didAttemptRender = false

    var body: some View {
        Group {
            if let renderedImage {
                ScrollView(.horizontal, showsIndicators: false) {
                    Image(uiImage: renderedImage)
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
            renderedImageData = nil
            renderedImageData = await ETIOSMathImageRenderer.imageData(for: request, textColor: textColor, fontScale: fontScale)
            didAttemptRender = true
        }
    }

    private var renderedImage: UIImage? {
        guard let renderedImageData else { return nil }
        return UIImage(data: renderedImageData, scale: UIScreen.main.scale)
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

enum ETIOSMathImageRenderer {
#if canImport(SwiftMath)
    private static let cache = NSCache<NSString, NSData>()
    // SwiftMath 共享字体及排版缓存；整个渲染操作必须串行，且不能占用主线程。
    private static let renderQueue = DispatchQueue(label: "com.ericterminal.els.math-render", qos: .userInitiated)

    static func imageData(
        for request: ETNativeMathMarkdownCodec.Request,
        textColor: ETIOSMathColorComponents,
        fontScale: Double
    ) async -> Data? {
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            renderQueue.async {
                let cacheKey = "\(request.renderKind.rawValue)|\(request.latex)|\(textColor.cacheKey)|\(fontScale)" as NSString
                // 队列内复查，使并发请求同一公式时只实际渲染一次。
                if let cachedData = cache.object(forKey: cacheKey) {
                    continuation.resume(returning: cachedData as Data)
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
                let data = renderedImage.pngData()
                if let data {
                    cache.setObject(data as NSData, forKey: cacheKey)
                }
                continuation.resume(returning: data)
            }
        }
    }
#else
    static func imageData(
        for request: ETNativeMathMarkdownCodec.Request,
        textColor: ETIOSMathColorComponents,
        fontScale: Double
    ) async -> Data? {
        _ = request
        _ = textColor
        _ = fontScale
        return nil
    }
#endif
}
