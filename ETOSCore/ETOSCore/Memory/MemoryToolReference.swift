import CryptoKit
import Foundation

extension MemoryItem {
    /// 首行让模型能辨认目标，短后缀区分同标题的条目；旧记忆也能即时生成标签。
    var toolLabel: String {
        let firstLine = content.drop(while: \.isWhitespace).prefix(40).prefix { !$0.isNewline }
        let title = firstLine.trimmingCharacters(in: .whitespaces)
        return "\(title)-\(id.uuidString.prefix(6).lowercased())"
    }

    /// 校验码绑定条目身份和编辑快照。检索产生的访问计数和后台嵌入不应使其失效。
    var toolVersion: String {
        get throws {
            var state = self
            state.embedding = []
            state.accessCount = 0
            state.lastAccessedAt = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            let bytes = try encoder.encode(state)
            return SHA256.hash(data: bytes).prefix(6).map { String(format: "%02x", $0) }.joined()
        }
    }
}
