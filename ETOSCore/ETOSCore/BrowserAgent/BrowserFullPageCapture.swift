// ============================================================================
// BrowserFullPageCapture.swift
// ============================================================================
// ETOS LLM Studio
//
// 全页截图分块捕获、后台拼接并按像素与文件字节预算裁剪。
// ============================================================================

import Foundation
#if canImport(WebKit) && canImport(UIKit) && !os(watchOS)
import WebKit
import UIKit
import ImageIO
import UniformTypeIdentifiers

enum BrowserFullPageCapture {
    private static let maximumCSSHeight: CGFloat = 30_000
    private static let maximumPixels = 20_000_000
    private static let maximumOutputBytes = 25 * 1_024 * 1_024

    private struct Chunk: @unchecked Sendable {
        let image: CGImage
        let cssHeight: CGFloat
    }

    private struct EncodedCapture: Sendable {
        let data: Data
        let width: Int
        let height: Int
        let wasTruncated: Bool
    }

    @MainActor
    static func capture(
        webView: WKWebView,
        sessionID: UUID,
        fullPage: Bool
    ) async throws -> BrowserAgentScreenshotResult {
        if !fullPage {
            let image = try await webView.takeSnapshot(configuration: nil)
            guard let data = image.pngData() else {
                throw BrowserAgentError.unsupported(
                    NSLocalizedString("无法编码网页截图。", comment: "Browser Agent screenshot encoding unavailable")
                )
            }
            let destination = try await write(data, sessionID: sessionID)
            return BrowserAgentScreenshotResult(
                uri: try BrowserAgentStorage.appURI(for: destination),
                width: Int(image.size.width * image.scale),
                height: Int(image.size.height * image.scale),
                fullPage: false,
                wasTruncated: false
            )
        }

        let metrics = try await pageMetrics(webView)
        let viewportWidth = max(webView.bounds.width, 1)
        let viewportHeight = max(webView.bounds.height, 1)
        let scale = max(webView.window?.screen.scale ?? UIScreen.main.scale, 1)
        let pixelLimitedHeight = CGFloat(Self.maximumPixels) / (viewportWidth * scale * scale)
        let captureHeight = min(metrics.scrollHeight, Self.maximumCSSHeight, pixelLimitedHeight)
        let requestedWasTruncated = captureHeight < metrics.scrollHeight
        var chunks: [Chunk] = []
        var offset: CGFloat = 0
        var restoredScrollPosition = false

        defer {
            if !restoredScrollPosition {
                Task { @MainActor in
                    _ = try? await webView.evaluateJavaScript("window.scrollTo(\(metrics.scrollX), \(metrics.scrollY)); true")
                }
            }
        }

        while offset < captureHeight {
            try Task.checkCancellation()
            let height = min(viewportHeight, captureHeight - offset)
            _ = try await webView.evaluateJavaScript("window.scrollTo(0, \(offset)); true")
            try await Task.sleep(nanoseconds: 50_000_000)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight)
            let image = try await webView.takeSnapshot(configuration: configuration)
            guard let cgImage = image.cgImage else {
                throw BrowserAgentError.unsupported(
                    NSLocalizedString("无法读取网页截图像素。", comment: "Browser Agent screenshot pixels unavailable")
                )
            }
            chunks.append(Chunk(image: cgImage, cssHeight: height))
            offset += height
        }

        _ = try? await webView.evaluateJavaScript("window.scrollTo(\(metrics.scrollX), \(metrics.scrollY)); true")
        restoredScrollPosition = true

        let encoded = try await Task.detached(priority: .utility) {
            try stitch(chunks: chunks, scale: scale, maximumBytes: maximumOutputBytes)
        }.value
        let destination = try await write(encoded.data, sessionID: sessionID)
        return BrowserAgentScreenshotResult(
            uri: try BrowserAgentStorage.appURI(for: destination),
            width: encoded.width,
            height: encoded.height,
            fullPage: true,
            wasTruncated: requestedWasTruncated || encoded.wasTruncated
        )
    }

    @MainActor
    private static func pageMetrics(_ webView: WKWebView) async throws -> (
        scrollHeight: CGFloat,
        scrollX: Double,
        scrollY: Double
    ) {
        let value = try await webView.evaluateJavaScript(
            """
            ({
              scrollHeight: Math.max(document.documentElement?.scrollHeight || 0, document.body?.scrollHeight || 0, window.innerHeight),
              scrollX: window.scrollX,
              scrollY: window.scrollY
            })
            """
        )
        guard let object = value as? [String: Any] else {
            throw BrowserAgentError.javaScriptFailed(
                NSLocalizedString("无法读取完整页面尺寸。", comment: "Browser Agent full page metrics unavailable")
            )
        }
        return (
            CGFloat((object["scrollHeight"] as? NSNumber)?.doubleValue ?? Double(webView.bounds.height)),
            (object["scrollX"] as? NSNumber)?.doubleValue ?? 0,
            (object["scrollY"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    private static func stitch(
        chunks: [Chunk],
        scale: CGFloat,
        maximumBytes: Int
    ) throws -> EncodedCapture {
        guard let first = chunks.first else {
            throw BrowserAgentError.unsupported(
                NSLocalizedString("没有可拼接的网页截图。", comment: "Browser Agent screenshot chunks missing")
            )
        }
        let width = first.image.width
        let heights = chunks.map { min(Int(($0.cssHeight * scale).rounded()), $0.image.height) }
        let availableHeight = heights.reduce(0, +)
        var heightLimit = availableHeight
        while heightLimit > 0 {
            let totalHeight = min(availableHeight, heightLimit)
            guard let context = CGContext(
                data: nil,
                width: width,
                height: totalHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw BrowserAgentError.unsupported(
                    NSLocalizedString("无法创建全页截图画布。", comment: "Browser Agent screenshot canvas unavailable")
                )
            }
            context.translateBy(x: 0, y: CGFloat(totalHeight))
            context.scaleBy(x: 1, y: -1)
            var y = 0
            for (chunk, sourceHeight) in zip(chunks, heights) where y < totalHeight {
                let height = min(sourceHeight, totalHeight - y)
                guard height > 0,
                      let cropped = chunk.image.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)) else {
                    continue
                }
                context.draw(cropped, in: CGRect(x: 0, y: y, width: width, height: height))
                y += height
            }
            guard let image = context.makeImage() else {
                throw BrowserAgentError.unsupported(
                    NSLocalizedString("无法生成全页截图。", comment: "Browser Agent screenshot image unavailable")
                )
            }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                throw BrowserAgentError.unsupported(
                    NSLocalizedString("无法创建 PNG 编码器。", comment: "Browser Agent PNG encoder unavailable")
                )
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw BrowserAgentError.unsupported(
                    NSLocalizedString("无法编码全页截图。", comment: "Browser Agent full screenshot encode failed")
                )
            }
            if data.length <= maximumBytes {
                return EncodedCapture(
                    data: data as Data,
                    width: width,
                    height: totalHeight,
                    wasTruncated: totalHeight < availableHeight
                )
            }
            heightLimit = heightLimit == 1 ? 0 : max(1, heightLimit * 3 / 4)
        }
        throw BrowserAgentError.unsupported(
            NSLocalizedString("全页截图超过输出预算。", comment: "Browser Agent screenshot output limit")
        )
    }

    private static func write(_ data: Data, sessionID: UUID) async throws -> URL {
        let filename = "browser-\(ISO8601DateFormatter().string(from: Date())).png"
        let destination = try await Task.detached(priority: .utility) {
            try BrowserAgentStorage.destinationURL(
                sessionID: sessionID,
                directoryName: "Screenshots",
                proposedFilename: filename
            )
        }.value
        try await Task.detached(priority: .utility) {
            try data.write(to: destination, options: .atomic)
        }.value
        return destination
    }
}
#endif
