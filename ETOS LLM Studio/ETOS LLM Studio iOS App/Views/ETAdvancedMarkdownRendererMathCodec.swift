// ============================================================================
// ETAdvancedMarkdownRendererMathCodec.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Markdown 中原生数学公式标记的编码、解码与转换。
// ============================================================================

import Foundation
import Shared

#if canImport(SwiftMath)
import SwiftMath
#endif

enum ETNativeMathMarkdownCodec {
    enum RenderKind: String, Hashable, Sendable {
        case inline
        case block
    }

    struct Request: Hashable, Sendable {
        let latex: String
        let renderKind: RenderKind
    }

    nonisolated private static let scheme = "etmath"

    nonisolated static var isAvailable: Bool {
#if canImport(SwiftMath)
        true
#else
        false
#endif
    }

    nonisolated static func transformedMarkdown(from segments: [ETMathContentSegment]) -> String {
        var result = ""
        result.reserveCapacity(segments.reduce(into: 0) { partialResult, segment in
            switch segment {
            case .text(let text):
                partialResult += text.count
            case .inlineMath(let latex), .blockMath(let latex):
                partialResult += latex.count + 48
            @unknown default:
                break
            }
        })

        for segment in segments {
            switch segment {
            case .text(let text):
                result.append(text)
            case .inlineMath(let latex):
                result.append(imageMarkdown(for: .init(latex: latex, renderKind: .inline)))
            case .blockMath(let latex):
                result.append(imageMarkdown(for: .init(latex: latex, renderKind: .block)))
            @unknown default:
                break
            }
        }

        return result
    }

    nonisolated static func request(from url: URL?) -> Request? {
        guard let url, url.scheme == scheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard let renderKindValue = components.queryItems?.first(where: { $0.name == "mode" })?.value,
              let renderKind = RenderKind(rawValue: renderKindValue),
              let encodedLatex = components.queryItems?.first(where: { $0.name == "latex" })?.value,
              let latex = decodeBase64URL(encodedLatex) else {
            return nil
        }
        return Request(latex: latex, renderKind: renderKind)
    }

    nonisolated private static func imageMarkdown(for request: Request) -> String {
        guard let url = url(for: request) else { return request.latex }
        return "![数学公式](\(url.absoluteString))"
    }

    nonisolated private static func url(for request: Request) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "render"
        components.queryItems = [
            URLQueryItem(name: "mode", value: request.renderKind.rawValue),
            URLQueryItem(name: "latex", value: encodeBase64URL(request.latex))
        ]
        return components.url
    }

    nonisolated private static func encodeBase64URL(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated private static func decodeBase64URL(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension ETNativeMathMarkdownCodec.RenderKind {
    func placeholderHeight(fontScale: Double) -> CGFloat {
        switch self {
        case .inline:
            return 18 * CGFloat(FontLibrary.normalizedFontScale(fontScale))
        case .block:
            return 28 * CGFloat(FontLibrary.normalizedFontScale(fontScale))
        }
    }

    func fallbackFontSize(fontScale: Double) -> CGFloat {
        switch self {
        case .inline:
            return 17 * CGFloat(FontLibrary.normalizedFontScale(fontScale))
        case .block:
            return 20 * CGFloat(FontLibrary.normalizedFontScale(fontScale))
        }
    }
}

#if canImport(SwiftMath)
extension ETNativeMathMarkdownCodec.RenderKind {
    func fontSize(fontScale: Double) -> CGFloat {
        switch self {
        case .inline:
            return 17 * CGFloat(FontLibrary.normalizedFontScale(fontScale))
        case .block:
            return 20 * CGFloat(FontLibrary.normalizedFontScale(fontScale))
        }
    }

    var labelMode: MTMathUILabelMode {
        switch self {
        case .inline:
            return .text
        case .block:
            return .display
        }
    }
}
#endif
