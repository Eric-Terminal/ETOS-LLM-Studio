import ETOSCore
import Foundation

struct MacRequestParameterRow: Identifiable, Equatable, Sendable {
    let id: UUID
    var key: String
    var value: String
    private let suggestionKey: String?
    private let suggestionValue: String?
    var isUneditedSuggestion: Bool { suggestionKey == key && suggestionValue == value }

    init(key: String = "", value: String = "", isSuggestion: Bool = false) {
        id = UUID(); self.key = key; self.value = value
        suggestionKey = isSuggestion ? key : nil; suggestionValue = isSuggestion ? value : nil
    }
}

/// 三种编辑方式共用核心解析器；转换失败时保留原稿，不能借切换方式清空错误输入。
struct MacRequestParameterDraft: Equatable, Sendable {
    var mode: Model.RequestBodyOverrideMode
    var rows: [MacRequestParameterRow]
    var text: String

    init() { mode = .rawJSON; rows = []; text = "{}" }

    /// 建议只携带字段结构；原始标量（包括令牌和其他选项的值）不会进入编辑文本。
    static func suggestion(parameters: [String: JSONValue], mode: Model.RequestBodyOverrideMode) -> MacRequestParameterDraft {
        var result = MacRequestParameterDraft()
        result.mode = mode
        if mode == .keyValue, parameters.keys.contains(where: { $0.isEmpty || $0 != $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            result.mode = .rawJSON
        }
        switch result.mode {
        case .keyValue:
            result.rows = parameters.sorted { $0.key < $1.key }.map { .init(key: $0.key, value: ParameterExpressionParser.serializeTemplateValue($0.value), isSuggestion: true) }
        case .expression:
            result.rows = ParameterExpressionParser.serializeTemplate(parameters: parameters).map { .init(value: $0) }
        case .rawJSON: break
        @unknown default: result.mode = .rawJSON
        }
        result.text = ParameterExpressionParser.serializeRawJSONTemplate(parameters: parameters)
        return result
    }

    init(parameters: [String: JSONValue], mode: Model.RequestBodyOverrideMode, rawJSON: String? = nil) {
        self.mode = mode
        rows = parameters.sorted { $0.key < $1.key }.map { key, value in
            // 值单独序列化，键值表中的键是字面量，不能让键里的等号改变解析边界。
            let expression = ParameterExpressionParser.serialize(parameters: ["value": value]).first ?? "value="
            return MacRequestParameterRow(key: key, value: String(expression.dropFirst("value=".count)))
        }
        if mode == .expression {
            rows = ParameterExpressionParser.serialize(parameters: parameters).map { MacRequestParameterRow(value: $0) }
        }
        text = rawJSON ?? ParameterExpressionParser.serializeRawJSONObject(parameters: parameters)
        // 外部 JSON 可以包含空键或带首尾空白的键；表单无法表示时直接保留 JSON。
        if mode != .rawJSON, (try? self.parameters()) != parameters { self.mode = .rawJSON; rows = [] }
    }

    func parameters() throws -> [String: JSONValue] {
        if mode == .rawJSON { return try ParameterExpressionParser.parseRawJSONObject(text) }
        let expressions: [ParameterExpressionParser.ParsedExpression] = try rows.compactMap { row in
            if mode == .keyValue, row.isUneditedSuggestion { return nil }
            let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if mode == .expression { return value.isEmpty ? nil : try ParameterExpressionParser.parse(value) }
            let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty && value.isEmpty { return nil }
            guard !key.isEmpty else { throw ParameterExpressionParser.ParserError.invalidKey }
            let parsed = value.isEmpty ? JSONValue.string("") : try ParameterExpressionParser.parse("value = \(row.value)").value
            return ParameterExpressionParser.ParsedExpression(key: key, value: parsed)
        }
        return ParameterExpressionParser.buildParameters(from: expressions)
    }

    func converted(to mode: Model.RequestBodyOverrideMode) throws -> MacRequestParameterDraft {
        let values = try parameters()
        let result = MacRequestParameterDraft(parameters: values, mode: mode)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard result.mode == mode,
              try encoder.encode(result.parameters()) == encoder.encode(values) else { throw MacRequestParameterError.lossyConversion }
        return result
    }
}

enum MacRequestParameterError: LocalizedError {
    case lossyConversion
    var errorDescription: String? { NSLocalizedString("这些参数无法无损转换为所选编辑方式，请继续使用当前方式。", comment: "") }
}
