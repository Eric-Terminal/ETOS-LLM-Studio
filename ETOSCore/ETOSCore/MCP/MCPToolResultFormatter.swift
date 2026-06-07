// ============================================================================
// MCPToolResultFormatter.swift
// ============================================================================
// 统一整理 MCP 工具结果的展示内容：
// - 提取适合折叠态展示的摘要
// - 优先抽取 MCP 标准包裹中的正文文本
// - 保留可读性更好的原始返回文本
// ============================================================================

import Foundation

public struct MCPToolResultDisplayModel: Equatable, Sendable {
    public let summaryText: String
    public let primaryContentText: String?
    public let rawDisplayText: String
    public let isStructuredMCPEnvelope: Bool
    public let shouldShowRawSection: Bool

    public init(
        summaryText: String,
        primaryContentText: String?,
        rawDisplayText: String,
        isStructuredMCPEnvelope: Bool,
        shouldShowRawSection: Bool
    ) {
        self.summaryText = summaryText
        self.primaryContentText = primaryContentText
        self.rawDisplayText = rawDisplayText
        self.isStructuredMCPEnvelope = isStructuredMCPEnvelope
        self.shouldShowRawSection = shouldShowRawSection
    }
}

/// Widget 工具的可渲染载荷。
public struct ToolWidgetPayload: Equatable, Sendable {
    public let title: String?
    public let widgetCode: String
    public let loadingMessages: [String]

    public init(title: String?, widgetCode: String, loadingMessages: [String] = []) {
        self.title = title
        self.widgetCode = widgetCode
        self.loadingMessages = loadingMessages
    }
}

/// 从工具参数或工具结果中提取 Widget 载荷。
public enum ToolWidgetPayloadParser {
    public static func parse(from rawText: String) -> ToolWidgetPayload? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            return parse(from: value)
        } catch {
            return nil
        }
    }

    private static func parse(from value: JSONValue) -> ToolWidgetPayload? {
        guard case .dictionary(let dictionary) = value else {
            return nil
        }

        if let payload = payload(from: dictionary) {
            return payload
        }

        if case .dictionary(let input)? = dictionary["input"],
           let payload = payload(from: input) {
            return payload
        }

        return nil
    }

    private static func payload(from dictionary: [String: JSONValue]) -> ToolWidgetPayload? {
        let widgetCodeKeys = ["widget_code", "widgetCode", "widget_html", "widgetHtml", "html"]
        guard let widgetCode = firstNonEmptyString(for: widgetCodeKeys, in: dictionary) else {
            return nil
        }

        let title = firstNonEmptyString(for: ["title", "name"], in: dictionary)
        let loadingMessages = stringArray(for: ["loading_messages", "loadingMessages"], in: dictionary)

        return ToolWidgetPayload(
            title: title,
            widgetCode: widgetCode,
            loadingMessages: loadingMessages
        )
    }

    private static func firstNonEmptyString(
        for keys: [String],
        in dictionary: [String: JSONValue]
    ) -> String? {
        for key in keys {
            guard case .string(let raw)? = dictionary[key] else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func stringArray(for keys: [String], in dictionary: [String: JSONValue]) -> [String] {
        for key in keys {
            guard let value = dictionary[key] else { continue }
            switch value {
            case .array(let items):
                let normalized = items.compactMap { item -> String? in
                    guard case .string(let raw) = item else { return nil }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                if !normalized.isEmpty {
                    return normalized
                }
            case .string(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return [trimmed]
                }
            default:
                continue
            }
        }
        return []
    }
}

public enum MCPToolResultFormatter {
    public static func displayModel(from rawResult: String, summaryLimit: Int = 90) -> MCPToolResultDisplayModel {
        let trimmedRaw = rawResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            return MCPToolResultDisplayModel(
                summaryText: "",
                primaryContentText: nil,
                rawDisplayText: "",
                isStructuredMCPEnvelope: false,
                shouldShowRawSection: false
            )
        }

        guard let data = trimmedRaw.data(using: .utf8) else {
            return plainTextFallbackModel(from: trimmedRaw, summaryLimit: summaryLimit)
        }

        let jsonValue: JSONValue
        do {
            jsonValue = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            return plainTextFallbackModel(from: trimmedRaw, summaryLimit: summaryLimit)
        }

        let isStructuredEnvelope = hasStructuredEnvelope(jsonValue)
        let primaryContent = primaryContent(from: jsonValue)
        let rawDisplayText = prettyPrintedText(from: jsonValue)
        let summaryText = primaryContent.map { truncatedSingleLine($0, limit: summaryLimit) }
            ?? structuredSummary(for: jsonValue, summaryLimit: summaryLimit)
            ?? truncatedSingleLine(trimmedRaw, limit: summaryLimit)

        let shouldShowRawSection: Bool
        if rawDisplayText.isEmpty {
            shouldShowRawSection = false
        } else if let primaryContent {
            shouldShowRawSection = normalizedComparisonText(primaryContent) != normalizedComparisonText(rawDisplayText)
        } else {
            shouldShowRawSection = true
        }

        return MCPToolResultDisplayModel(
            summaryText: summaryText,
            primaryContentText: primaryContent,
            rawDisplayText: rawDisplayText,
            isStructuredMCPEnvelope: isStructuredEnvelope,
            shouldShowRawSection: shouldShowRawSection
        )
    }

    private static func plainTextFallbackModel(from trimmedRaw: String, summaryLimit: Int) -> MCPToolResultDisplayModel {
        MCPToolResultDisplayModel(
            summaryText: truncatedSingleLine(trimmedRaw, limit: summaryLimit),
            primaryContentText: trimmedRaw,
            rawDisplayText: trimmedRaw,
            isStructuredMCPEnvelope: false,
            shouldShowRawSection: false
        )
    }

    private static func hasStructuredEnvelope(_ value: JSONValue) -> Bool {
        guard case .dictionary(let dictionary) = value,
              case .array? = dictionary["content"] else {
            return false
        }
        return true
    }

    private static func primaryContent(from value: JSONValue) -> String? {
        if let envelopeText = envelopePrimaryText(from: value) {
            return envelopeText
        }

        guard case .string(let text) = value else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func envelopePrimaryText(from value: JSONValue) -> String? {
        guard case .dictionary(let dictionary) = value,
              case .array(let contentItems)? = dictionary["content"],
              let firstItem = contentItems.first,
              case .dictionary(let payload) = firstItem,
              case .string(let text)? = payload["text"] else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func structuredSummary(for value: JSONValue, summaryLimit: Int) -> String? {
        switch value {
        case .dictionary(let dictionary):
            if case .array(let contentItems)? = dictionary["content"] {
                return "返回 MCP 内容（\(contentItems.count) 段）"
            }
            return "返回 JSON 数据（\(dictionary.count) 个字段）"
        case .array(let array):
            return "返回 JSON 数组（\(array.count) 项）"
        case .bool:
            return "返回 JSON 布尔值"
        case .int, .double:
            return "返回 JSON 数值"
        case .null:
            return "返回空值"
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : truncatedSingleLine(trimmed, limit: summaryLimit)
        }
    }

    private static func prettyPrintedText(from value: JSONValue) -> String {
        switch value {
        case .dictionary, .array:
            let object = value.toAny()
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
                  let string = String(data: data, encoding: .utf8) else {
                return value.prettyPrintedCompact()
            }
            return string
        case .string(let text):
            return text
        case .int, .double, .bool, .null:
            return value.prettyPrintedCompact()
        }
    }

    private static func truncatedSingleLine(_ text: String, limit: Int) -> String {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard normalized.count > limit else {
            return normalized
        }
        return String(normalized.prefix(limit)) + "..."
    }

    private static func normalizedComparisonText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
