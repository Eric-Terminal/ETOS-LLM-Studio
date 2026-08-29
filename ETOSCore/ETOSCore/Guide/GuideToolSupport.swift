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

    public static let listSourceDirectory = InternalToolDefinition(
        name: "list_source_directory",
        description: "列出当前 App 精确版本源码中某个目录的直接子项。仅在文档不足时使用。",
        parameters: objectSchema(
            properties: [
                "path": .dictionary([
                    "type": .string("string"),
                    "description": .string("仓库相对目录；空字符串表示仓库根目录")
                ])
            ],
            required: ["path"]
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

    public static let listProviderTemplates = InternalToolDefinition(
        name: "list_guide_provider_templates",
        description: "列出当前 App 版本内置的可信云端提供商模板。首次配置云端模型时先调用此工具。",
        parameters: objectSchema(properties: [:])
    )

    public static let readProviderTemplate = InternalToolDefinition(
        name: "read_guide_provider_template",
        description: "按模板 ID 读取可信的基础地址与 API 格式，不包含任何密钥。",
        parameters: objectSchema(
            properties: [
                "id": stringProperty("list_guide_provider_templates 返回的模板 ID")
            ],
            required: ["id"]
        )
    )

    public static let updateProviderConfiguration = InternalToolDefinition(
        name: "propose_provider_configuration",
        description: "提出提供商配置修改。只填写确实需要变化的字段；API Key 仅在用户主动提供新值时填写。",
        parameters: objectSchema(properties: [
            "name": stringProperty("提供商显示名称"),
            "base_url": stringProperty("API 基础地址"),
            "chat_endpoint_path": stringProperty("OpenAI 兼容聊天端点后缀"),
            "api_format": stringProperty("openai-compatible、openai-responses、gemini 或 anthropic"),
            "api_key": stringProperty("用户刚刚主动提供的新 API Key；不可尝试读取现有值")
        ])
    )

    public static let updateModelConfiguration = InternalToolDefinition(
        name: "propose_model_configuration",
        description: "提出当前模型的基础配置修改。只填写确实需要变化的字段。",
        parameters: objectSchema(properties: [
            "display_name": stringProperty("App 内显示名称"),
            "model_id": stringProperty("API 请求使用的模型 ID"),
            "picker_group": stringProperty("模型选择器分组名称，空字符串表示不分组"),
            "api_format_override": stringProperty("空字符串表示跟随提供商，或填写支持的 API 格式"),
            "supports_tool_calling": boolProperty("模型是否支持工具调用")
        ])
    )

    public static let replaceModelRequestBody = InternalToolDefinition(
        name: "propose_model_request_body_json",
        description: "用一个 JSON 对象替换当前模型的自定义请求体。需要认证字段时必须解释用途，并等待用户在原生预览中确认。",
        parameters: objectSchema(
            properties: [
                "json": .dictionary([
                    "type": .string("object"),
                    "description": .string("与默认请求体合并的 JSON 对象")
                ])
            ],
            required: ["json"]
        )
    )

    public static let updateGlobalProxy = InternalToolDefinition(
        name: "propose_global_proxy_configuration",
        description: "提出全局代理配置修改。密码仅在用户主动提供新值时填写。",
        parameters: objectSchema(properties: [
            "enabled": boolProperty("是否启用全局代理"),
            "type": stringProperty("http 或 socks5"),
            "host": stringProperty("代理主机名或 IP，不含协议"),
            "port": integerProperty("1 到 65535 的端口"),
            "username": stringProperty("代理用户名，空字符串表示清除"),
            "password": stringProperty("用户刚刚主动提供的新代理密码；不可尝试读取现有值")
        ])
    )

    public static let updateMCPPreferences = InternalToolDefinition(
        name: "propose_mcp_preferences",
        description: "提出 MCP 工具箱总开关修改。",
        parameters: objectSchema(properties: [
            "chat_tools_enabled": boolProperty("是否向普通聊天模型暴露 MCP 工具"),
            "tool_call_title_enabled": boolProperty("是否让 AI 生成 MCP 调用标题")
        ])
    )

    public static let createMCPServer = InternalToolDefinition(
        name: "propose_mcp_server_creation",
        description: "提出创建一个 HTTP、SSE 或本地 stdio MCP Server。配置会先经过客户端校验和原生预览，用户确认后才保存。",
        parameters: objectSchema(
            properties: [
                "name": stringProperty("服务器显示名称"),
                "configuration": .dictionary([
                    "type": .string("object"),
                    "description": .string("单个标准 MCP Server 配置：HTTP 使用 type、url、headers；SSE 另可使用 messageUrl；stdio 使用 command、args、env、cwd")
                ]),
                "notes": stringProperty("可选备注"),
                "select_for_chat": boolProperty("保存后是否加入普通聊天工具")
            ],
            required: ["name", "configuration"]
        )
    )

    public static let requestModelSetupSecret = InternalToolDefinition(
        name: "request_model_setup_secret",
        description: "请求客户端显示独立的 API Key 安全输入界面。工具不能读取用户输入的真实值。",
        parameters: objectSchema(properties: [:])
    )

    public static let proposeModelSetupTest = InternalToolDefinition(
        name: "propose_model_setup_test",
        description: "生成一次真实连接测试的待确认操作。只有用户确认后客户端才请求目标提供商。",
        parameters: objectSchema(properties: [:])
    )

    public static let proposeSetupModelSelection = InternalToolDefinition(
        name: "propose_setup_model_selection",
        description: "从客户端真实获取的模型列表中提出一个模型选择。不能编造列表中不存在的模型 ID。",
        parameters: objectSchema(
            properties: [
                "model_id": stringProperty("真实模型列表中的 API 模型 ID")
            ],
            required: ["model_id"]
        )
    )

    public static let proposeModelSetupCommit = InternalToolDefinition(
        name: "propose_model_setup_commit",
        description: "生成保存并使用当前配置草稿的最终预览。只有用户确认后才会原子写入。",
        parameters: objectSchema(properties: [:])
    )

    public static let showNoAPIAlternatives = InternalToolDefinition(
        name: "show_no_api_alternatives",
        description: "仅当用户明确没有 API 且不愿付费时，请求客户端显示按界面语言选择的官方聊天应用。",
        parameters: objectSchema(properties: [:])
    )

    public static let knowledgeDefinitions = [
        currentPageContext,
        searchDocuments,
        readDocument,
        searchSourceTree,
        listSourceDirectory,
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

    private static func stringProperty(_ description: String) -> JSONValue {
        .dictionary(["type": .string("string"), "description": .string(description)])
    }

    private static func boolProperty(_ description: String) -> JSONValue {
        .dictionary(["type": .string("boolean"), "description": .string(description)])
    }

    private static func integerProperty(_ description: String) -> JSONValue {
        .dictionary(["type": .string("integer"), "description": .string(description)])
    }
}

public struct GuideMCPServerProposalConfiguration: Sendable {
    public let server: MCPServerConfiguration
    public let containsSensitiveValues: Bool

    public init(server: MCPServerConfiguration, containsSensitiveValues: Bool) {
        self.server = server
        self.containsSensitiveValues = containsSensitiveValues
    }
}

public enum GuideMCPServerProposalSupport {
    private static let allowedKeys: Set<String> = [
        "name",
        "configuration",
        "notes",
        "select_for_chat"
    ]

    public static func buildProposal(
        call: InternalToolCall,
        pageID: GuidePageID
    ) throws -> GuideActionProposal {
        guard call.toolName == GuideToolCatalog.createMCPServer.name else {
            throw GuideError.unsupportedTool(call.toolName)
        }
        let arguments = try GuideToolArguments.decode(call.arguments)
        let decoded = try decode(arguments)
        let displayValue = GuideSecretRedactor.redact(.dictionary(arguments))
        return GuideActionProposal(
            pageID: pageID,
            toolCallID: call.id,
            toolName: call.toolName,
            summary: decoded.containsSensitiveValues
                ? NSLocalizedString("创建 MCP 服务器（包含认证或环境变量，请仔细确认）", comment: "MCP 向导敏感创建提案摘要")
                : NSLocalizedString("创建 MCP 服务器", comment: "MCP 向导创建提案摘要"),
            mutations: [GuideSettingMutation(
                path: "server",
                label: NSLocalizedString("MCP 服务器配置", comment: "MCP 向导创建修改字段"),
                oldValue: nil,
                newValue: displayValue
            )],
            arguments: arguments
        )
    }

    public static func decode(
        _ arguments: [String: JSONValue]
    ) throws -> GuideMCPServerProposalConfiguration {
        try GuideToolArguments.requireOnlyKeys(allowedKeys, in: arguments)
        let name = try GuideToolArguments.string("name", in: arguments)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              case .dictionary(let configuration)? = arguments["configuration"] else {
            throw GuideError.invalidToolArguments
        }
        let notes = try GuideToolArguments.optionalString("notes", in: arguments)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectForChat = try GuideToolArguments.optionalBool("select_for_chat", in: arguments) ?? false
        let root = JSONValue.dictionary([
            "mcpServers": .dictionary([name: .dictionary(configuration)])
        ])
        let data = try JSONSerialization.data(withJSONObject: root.toAny(), options: [.sortedKeys])
        let imported = try MCPServerConfigurationTransferService.importConfigurations(from: data)
        guard imported.servers.count == 1, imported.skippedNames.isEmpty else {
            throw GuideError.invalidToolArguments
        }
        var server = imported.servers[0]
        server.notes = notes?.isEmpty == false ? notes : nil
        server.isSelectedForChat = selectForChat
        let hasEnvironmentValues = ["env", "environment"].contains { key in
            guard case .dictionary(let values)? = configuration[key] else { return false }
            return !values.isEmpty
        }
        return GuideMCPServerProposalConfiguration(
            server: server,
            containsSensitiveValues: !imported.sensitiveServerNames.isEmpty || hasEnvironmentValues
        )
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

    public static func optionalString(_ key: String, in arguments: [String: JSONValue]) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard case .string(let string) = value else { throw GuideError.invalidToolArguments }
        return string
    }

    public static func optionalBool(_ key: String, in arguments: [String: JSONValue]) throws -> Bool? {
        guard let value = arguments[key] else { return nil }
        guard case .bool(let bool) = value else { throw GuideError.invalidToolArguments }
        return bool
    }

    public static func optionalInteger(_ key: String, in arguments: [String: JSONValue]) throws -> Int? {
        guard arguments[key] != nil else { return nil }
        return try integer(key, in: arguments)
    }

    public static func encodedResult(_ value: JSONValue) -> String {
        value.prettyPrintedCompact()
    }

    public static func requireOnlyKeys(
        _ allowedKeys: Set<String>,
        in arguments: [String: JSONValue]
    ) throws {
        guard arguments.keys.allSatisfy(allowedKeys.contains) else {
            throw GuideError.invalidToolArguments
        }
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
