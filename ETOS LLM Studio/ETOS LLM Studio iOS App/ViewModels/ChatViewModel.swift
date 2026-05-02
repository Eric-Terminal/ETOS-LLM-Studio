// ============================================================================
// ChatViewModel.swift (iOS)
// ============================================================================
// ETOS LLM Studio iOS App 视图模型
//
// 说明:
// - 复用 Shared.ChatService 提供的业务逻辑
// - 抽离 watchOS 相关实现，改用 UIKit 生命周期事件
// - 为 iOS 界面提供消息、会话、设置等绑定数据
// ============================================================================

import Combine
import CoreImage
import Foundation
import SwiftUI
@preconcurrency import MarkdownUI
import Shared
import os.log
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatViewModel")


struct ETPreparedMarkdownRenderPayload: Equatable, @unchecked Sendable {
    let sourceText: String
    let normalizedText: String
    let markdownContent: MarkdownContent
    let nativeMathMarkdownContent: MarkdownContent?
    let mathSegments: [ETMathContentSegment]
    let containsMathContent: Bool
    let containsMermaidContent: Bool
    let thinkingTitle: String?

    nonisolated static func build(from sourceText: String) async -> ETPreparedMarkdownRenderPayload {
        let normalizedText = normalizedMarkdownForStreaming(sourceText)
        let mathSegments = ETMathContentParser.parseSegments(in: normalizedText)
        let containsMath = mathSegments.contains { segment in
            switch segment {
            case .text:
                return false
            case .inlineMath, .blockMath:
                return true
            }
        }
        let containsMermaid = containsMermaidFence(in: normalizedText)
        return ETPreparedMarkdownRenderPayload(
            sourceText: sourceText,
            normalizedText: normalizedText,
            markdownContent: MarkdownContent(normalizedText),
            nativeMathMarkdownContent: buildNativeMathMarkdownContent(
                mathSegments: mathSegments,
                containsMath: containsMath,
                containsMermaid: containsMermaid
            ),
            mathSegments: mathSegments,
            containsMathContent: containsMath,
            containsMermaidContent: containsMermaid,
            thinkingTitle: extractThinkingTitle(from: normalizedText)
        )
    }

    nonisolated static func buildNativeMathMarkdownContent(
        mathSegments: [ETMathContentSegment],
        containsMath: Bool,
        containsMermaid: Bool
    ) -> MarkdownContent? {
        guard containsMath, !containsMermaid, ETNativeMathMarkdownCodec.isAvailable else {
            return nil
        }
        return MarkdownContent(ETNativeMathMarkdownCodec.transformedMarkdown(from: mathSegments))
    }

    nonisolated static func normalizedMarkdownForStreaming(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var normalizedLines: [String] = []
        normalizedLines.reserveCapacity(lines.count)
        var openedFence: (marker: Character, count: Int, infoToken: String?)?

        for line in lines {
            guard let fence = parseFenceLine(line) else {
                normalizedLines.append(line)
                continue
            }
            if let currentFence = openedFence {
                let isSameFenceFamily = currentFence.marker == fence.marker
                    && fence.count >= currentFence.count
                let trimmedTail = fence.tail.trimmingCharacters(in: .whitespacesAndNewlines)
                let isStrictClosingFence = trimmedTail.isEmpty
                let isRepeatedInfoClosingFence = !trimmedTail.isEmpty
                    && fence.infoToken == currentFence.infoToken

                if isSameFenceFamily && (isStrictClosingFence || isRepeatedInfoClosingFence) {
                    let closingFence = String(repeating: String(currentFence.marker), count: max(3, currentFence.count))
                    normalizedLines.append(closingFence)
                    openedFence = nil
                } else {
                    normalizedLines.append(line)
                }
            } else {
                openedFence = (marker: fence.marker, count: fence.count, infoToken: fence.infoToken)
                normalizedLines.append(line)
            }
        }

        var normalizedText = normalizedLines.joined(separator: "\n")
        guard let openedFence else { return normalizedText }

        let closingFence = String(repeating: String(openedFence.marker), count: max(3, openedFence.count))
        if normalizedText.hasSuffix("\n") {
            normalizedText += closingFence
        } else {
            normalizedText += "\n" + closingFence
        }
        return normalizedText
    }

    nonisolated static func extractThinkingTitle(from text: String) -> String? {
        for line in text.components(separatedBy: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("**"), trimmed.hasSuffix("**"), trimmed.count > 4 {
                let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
                let end = trimmed.index(trimmed.endIndex, offsetBy: -2)
                let title = trimmed[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    return title
                }
            }

            let headingPrefix = trimmed.prefix { $0 == "#" }
            if !headingPrefix.isEmpty,
               headingPrefix.count <= 6,
               trimmed.dropFirst(headingPrefix.count).first?.isWhitespace == true {
                let title = trimmed
                    .dropFirst(headingPrefix.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    return title
                }
            }
        }
        return nil
    }

    nonisolated static func containsMermaidFence(in text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            guard let fence = parseFenceLine(line) else { continue }
            let infoToken = fence.tail
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .first?
                .lowercased()
            if infoToken == "mermaid" || infoToken == "mmd" {
                return true
            }
        }
        return false
    }

    nonisolated static func parseFenceLine(_ line: String) -> (marker: Character, count: Int, tail: String, infoToken: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else {
            return nil
        }

        var count = 0
        for character in trimmed {
            guard character == marker else { break }
            count += 1
        }
        guard count >= 3 else { return nil }

        let startIndex = trimmed.index(trimmed.startIndex, offsetBy: count)
        let tail = String(trimmed[startIndex...])
        let infoToken = tail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map { String($0).lowercased() }
        return (marker: marker, count: count, tail: tail, infoToken: infoToken)
    }
}


actor ETMarkdownPrecomputeWorker {
    static let shared = ETMarkdownPrecomputeWorker()

    var cache: [String: ETPreparedMarkdownRenderPayload] = [:]
    var keyOrder: [String] = []
    let cacheLimit = 240

    func prepare(source: String) async -> ETPreparedMarkdownRenderPayload {
        if let cached = cache[source] {
            return cached
        }

        let prepared = await ETPreparedMarkdownRenderPayload.build(from: source)
        cache[source] = prepared
        keyOrder.append(source)
        trimIfNeeded()
        return prepared
    }

    func trimIfNeeded() {
        while keyOrder.count > cacheLimit {
            let removed = keyOrder.removeFirst()
            cache.removeValue(forKey: removed)
        }
    }
}
