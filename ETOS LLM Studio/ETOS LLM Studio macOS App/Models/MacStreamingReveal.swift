import ETOSCore
import Foundation
import SwiftUI

struct MacStreamingRevealAttribute: TextAttribute, Sendable {
    let startedAt: TimeInterval
    let stagger: Double
}

/// 后台组成只读 Text；每批只保留尾部最多 160 个组合字符的动画状态。
struct MacStreamingReveal: @unchecked Sendable {
    let id = UUID()
    let source: String
    let utf16Length: Int
    let text: Text
    let attributes: [Int: MacStreamingRevealAttribute]
    let endsAt: TimeInterval

    init(source: String, previous: Self?, now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        self.source = source
        utf16Length = source.utf16.count
        let isAppend = previous.map { source.hasPrefix($0.source) } ?? true
        let previousLength = isAppend ? previous?.utf16Length ?? 0 : utf16Length
        let suffix = source.suffix(160)
        let start = suffix.startIndex
        let prefix = String(source[..<start])
        var result = Text(verbatim: prefix)
        var offset = prefix.utf16.count
        var attributes: [Int: MacStreamingRevealAttribute] = [:]
        let newCount = max(1, suffix.reduce(0) { count, character in count + String(character).utf16.count })
        var newOffset = 0
        for character in suffix {
            let value = String(character)
            var part = Text(verbatim: value)
            let attribute: MacStreamingRevealAttribute?
            if offset >= previousLength {
                attribute = .init(startedAt: now, stagger: Double(newOffset) / Double(newCount))
                newOffset += value.utf16.count
            } else { attribute = isAppend ? previous?.attributes[offset] : nil }
            if let attribute, now < attribute.startedAt + 0.55 {
                attributes[offset] = attribute
                part = part.customAttribute(attribute)
            }
            result = Text("\(result)\(part)")
            offset += value.utf16.count
        }
        self.attributes = attributes
        text = result
        endsAt = attributes.values.map { $0.startedAt + 0.55 }.max() ?? now
    }
}
