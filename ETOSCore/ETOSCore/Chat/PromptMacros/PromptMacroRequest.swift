import Foundation

/// 只持有发送副本；字面宏在其他模板链路完成后还原，避免再次被当作可执行宏。
struct PromptMacroRequest: Sendable {
    let templates: PromptMacroTemplates
    let messages: [ChatMessage]
    private let literals: [String: String]

    init(templates: PromptMacroTemplates, messages: [ChatMessage], values: [String: String]) {
        var literals: [String: String] = [:]
        let sources = templates.texts + messages.map(\.content) + Array(values.values)
        var namespace = "\u{E000}ETOS.literal:"
        while sources.contains(where: { $0.contains(namespace) }) {
            namespace.append(":")
        }
        func protectLiteral(_ text: String) -> String {
            // 同一字面宏使用稳定标记，避免影响角色 pick 宏按输入文本计算的种子。
            // 命名空间避开输入已有文本；宏名称内不含括号，其他解析器不会识别它。
            let marker = "\(namespace)\(text.dropFirst(2).dropLast(2))\u{E001}"
            literals[marker] = text
            return marker
        }

        self.templates = templates.rendered(values: values, literalTransform: protectLiteral)
        self.messages = messages.map { message in
            guard message.role == .user else { return message }
            var rendered = message
            rendered.content = PromptMacroResolver.render(
                message.content, values: values, literalTransform: protectLiteral
            )
            return rendered
        }
        self.literals = literals
    }

    func restoringLiterals(in messages: [ChatMessage]) -> [ChatMessage] {
        guard !literals.isEmpty else { return messages }
        return messages.map { message in
            guard message.content.contains("\u{E000}") else { return message }
            var restored = message
            for (marker, text) in literals {
                restored.content = restored.content.replacingOccurrences(of: marker, with: text)
            }
            return restored
        }
    }
}
