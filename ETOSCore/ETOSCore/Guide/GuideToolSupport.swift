// ============================================================================
// GuideToolSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 向导专属工具目录与参数解析。这些定义不会进入普通聊天工具中心。
// ============================================================================

import Foundation

public enum GuideToolCatalog {
    public static let currentPageContext = InternalToolDefinition(
        name: "get_current_page_context",
        description: "读取用户当前所在页面及经过脱敏的最新配置快照。",
        parameters: objectSchema(properties: [:])
    )

    public static let searchDocuments = InternalToolDefinition(
        name: "search_guide_documents",
        description: "搜索 ETOS LLM Studio 内置使用文档。先搜索，再按文档 ID 读取正文。",
        parameters: objectSchema(
            properties: [
                "query": .dictionary([
                    "type": .string("string"),
                    "description": .string("要查找的功能、设置或错误现象")
                ])
            ],
            required: ["query"]
        )
    )

    public static let readDocument = InternalToolDefinition(
        name: "read_guide_document",
        description: "按文档 ID 读取内置文档正文。",
        parameters: objectSchema(
            properties: [
                "id": .dictionary([
                    "type": .string("string"),
                    "description": .string("搜索结果返回的文档 ID")
                ])
            ],
            required: ["id"]
        )
    )

    public static let searchSourceTree = InternalToolDefinition(
        name: "search_source_tree",
        description: "在与当前 App 构建完全对应的源码目录树中搜索路径。仅在文档不足时使用。",
        parameters: objectSchema(
            properties: [
                "query": .dictionary([
                    "type": .string("string"),
                    "description": .string("文件名或目录名关键词")
                ])
            ],
            required: ["query"]
        )
    )

    public static let readSourceFile = InternalToolDefinition(
        name: "read_source_file",
        description: "读取当前 App 精确版本中的一个源码文件片段。必须先从源码树取得路径。",
        parameters: objectSchema(
            properties: [
                "path": .dictionary([
                    "type": .string("string"),
                    "description": .string("仓库相对路径")
                ]),
                "start_line": .dictionary([
                    "type": .string("integer"),
                    "minimum": .int(1)
                ]),
                "end_line": .dictionary([
                    "type": .string("integer"),
                    "minimum": .int(1)
                ])
            ],
            required: ["path", "start_line", "end_line"]
        )
    )

    public static let knowledgeDefinitions = [
        currentPageContext,
        searchDocuments,
        readDocument,
        searchSourceTree,
        readSourceFile
    ]

    public static func objectSchema(
        properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .dictionary(properties),
            "additionalProperties": .bool(false)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(JSONValue.string))
        }
        return .dictionary(schema)
    }
}

public enum GuideToolArguments {
    public static func decode(_ arguments: String) throws -> [String: JSONValue] {
        guard let data = arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GuideError.invalidToolArguments
        }
        return try object.mapValues(jsonValue(from:))
    }

    public static func string(_ key: String, in arguments: [String: JSONValue]) throws -> String {
        guard case .string(let value)? = arguments[key] else {
            throw GuideError.invalidToolArguments
        }
        return value
    }

    public static func integer(_ key: String, in arguments: [String: JSONValue]) throws -> Int {
        switch arguments[key] {
        case .int(let value):
            return value
        case .double(let value) where value.rounded() == value:
            return Int(value)
        default:
            throw GuideError.invalidToolArguments
        }
    }

    public static func encodedResult(_ value: JSONValue) -> String {
        value.prettyPrintedCompact()
    }

    private static func jsonValue(from value: Any) throws -> JSONValue {
        switch value {
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            let double = value.doubleValue
            return double.rounded() == double ? .int(value.intValue) : .double(double)
        case let value as [String: Any]:
            return .dictionary(try value.mapValues(jsonValue(from:)))
        case let value as [Any]:
            return .array(try value.map(jsonValue(from:)))
        case _ as NSNull:
            return .null
        default:
            throw GuideError.invalidToolArguments
        }
    }
}
