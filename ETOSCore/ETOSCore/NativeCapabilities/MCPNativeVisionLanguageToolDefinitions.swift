// ============================================================================
// MCPNativeVisionLanguageToolDefinitions.swift
// ============================================================================
// ETOS LLM Studio
//
// Vision 与 NaturalLanguage 端侧工具的 MCP schema。
// ============================================================================

import Foundation
import MCP

enum MCPNativeVisionLanguageToolDefinitions {
    private static let toolIDs: Set<String> = [
        "vision.recognize_text",
        "vision.detect_barcodes",
        "vision.classify_image",
        "vision.detect_document",
        "language.detect",
        "language.tokenize",
        "language.sentiment",
        "language.entities"
    ]

    static func contains(_ toolID: String) -> Bool {
        toolIDs.contains(toolID)
    }

    static var descriptions: [MCPToolDescription] {
        definitions.map { definition in
            MCPToolDescription(
                toolId: definition.id,
                description: NSLocalizedString(definition.summary, comment: "Vision language MCP tool description"),
                inputSchema: definition.schema
            )
        }
    }

    static var availableDescriptions: [MCPToolDescription] {
        descriptions.filter { isToolAvailableOnCurrentPlatform($0.toolId) }
    }

    static func isToolAvailableOnCurrentPlatform(_ toolID: String) -> Bool {
        if toolID.hasPrefix("vision.") {
            #if canImport(Vision) && canImport(ImageIO)
            return true
            #else
            return false
            #endif
        }
        if toolID.hasPrefix("language.") {
            #if canImport(NaturalLanguage)
            return true
            #else
            return false
            #endif
        }
        return false
    }

    private static var definitions: [Definition] {
        [
            tool("vision.recognize_text", "使用 Vision 在设备端识别 app:// 图片中的文字，返回有界文本、置信度与归一化边界。", imageObject([
                "recognition_level": enumeration("识别模式，默认 accurate。", ["accurate", "fast"]),
                "languages": stringArray("可选 BCP-47 识别语言列表。"),
                "uses_language_correction": boolean("是否启用系统语言纠正，默认 true。"),
                "maximum_results": integer("最大文本观察数，默认 100，最大 300。", 1, 300)
            ])),
            tool("vision.detect_barcodes", "使用 Vision 在设备端检测 app:// 图片中的条码和二维码，不访问相机。", imageObject([
                "symbologies": stringArray("可选 Vision 条码制式 raw value 列表。"),
                "maximum_results": integer("最大条码结果数，默认 50，最大 100。", 1, 100)
            ])),
            tool("vision.classify_image", "使用 Vision 的系统图像分类器在设备端分析 app:// 图片。", imageObject([
                "minimum_confidence": number("最低置信度 0 到 1，默认 0.01。"),
                "maximum_results": integer("最大分类数，默认 20，最大 100。", 1, 100)
            ])),
            tool("vision.detect_document", "使用 Vision 在设备端检测 app:// 图片中最显著的文档四边形。", imageObject()),
            tool("language.detect", "使用 NaturalLanguage 在设备端检测文本语言并返回有界候选概率。", textObject([
                "maximum_results": integer("最大语言候选数，默认 5，最大 20。", 1, 20)
            ])),
            tool("language.tokenize", "使用 NaturalLanguage 在设备端分词、分句或分段，并返回 UTF-16 偏移。", textObject([
                "unit": enumeration("切分单位，默认 word。", ["word", "sentence", "paragraph"]),
                "maximum_results": integer("最大结果数，默认 500，最大 2000。", 1, 2_000)
            ])),
            tool("language.sentiment", "使用 NaturalLanguage 在设备端按文本块计算情感分数；不会启动大模型。", textObject([
                "maximum_results": integer("最大分块结果数，默认 100，最大 500。", 1, 500)
            ])),
            tool("language.entities", "使用 NaturalLanguage 在设备端识别人名、地名和组织名。", textObject([
                "maximum_results": integer("最大实体结果数，默认 200，最大 1000。", 1, 1_000)
            ]))
        ]
    }

    private struct Definition {
        let id: String
        let summary: String
        let schema: JSONValue
    }

    private static func tool(_ id: String, _ summary: String, _ schema: JSONValue) -> Definition {
        Definition(id: id, summary: summary, schema: schema)
    }

    private static func imageObject(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var properties = extra
        properties["source"] = string("输入图片的 app:// URI。")
        properties["orientation"] = integer("可选 EXIF 方向 1 到 8，默认 1。", 1, 8)
        return object(properties, required: ["source"])
    }

    private static func textObject(_ extra: [String: JSONValue]) -> JSONValue {
        var properties = extra
        properties["text"] = string("待分析文本，UTF-8 最大 256 KiB。")
        return object(properties, required: ["text"])
    }

    private static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .dictionary([
            "type": .string("object"),
            "properties": .dictionary(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false)
        ])
    }

    private static func string(_ description: String) -> JSONValue {
        typed("string", description)
    }

    private static func number(_ description: String) -> JSONValue {
        typed("number", description)
    }

    private static func boolean(_ description: String) -> JSONValue {
        typed("boolean", description)
    }

    private static func integer(_ description: String, _ minimum: Int, _ maximum: Int) -> JSONValue {
        .dictionary([
            "type": .string("integer"),
            "description": .string(NSLocalizedString(description, comment: "Vision language integer parameter")),
            "minimum": .int(minimum),
            "maximum": .int(maximum)
        ])
    }

    private static func enumeration(_ description: String, _ values: [String]) -> JSONValue {
        .dictionary([
            "type": .string("string"),
            "description": .string(NSLocalizedString(description, comment: "Vision language enum parameter")),
            "enum": .array(values.map(JSONValue.string))
        ])
    }

    private static func stringArray(_ description: String) -> JSONValue {
        .dictionary([
            "type": .string("array"),
            "description": .string(NSLocalizedString(description, comment: "Vision language array parameter")),
            "items": .dictionary(["type": .string("string")]),
            "maxItems": .int(32)
        ])
    }

    private static func typed(_ type: String, _ description: String) -> JSONValue {
        .dictionary([
            "type": .string(type),
            "description": .string(NSLocalizedString(description, comment: "Vision language parameter"))
        ])
    }
}
