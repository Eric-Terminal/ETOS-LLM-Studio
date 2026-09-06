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

    public static let searchSourceCode = InternalToolDefinition(
        name: "search_source_code",
        description: "在当前 App 精确版本的源码内容中全文搜索，返回文件路径、行号与单行预览。仅在文档不足时使用，找到位置后再分段读取源码。",
        parameters: objectSchema(
            properties: [
                "query": .dictionary([
                    "type": .string("string"),
                    "description": .string("要定位的类型名、函数名、配置键或代码片段")
                ]),
                "path_prefix": .dictionary([
                    "type": .string("string"),
                    "description": .string("可选的仓库相对目录前缀，用于缩小搜索范围")
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
        description: "按行读取当前 App 精确版本中的源码片段，单次最多 240 行；返回总行数和是否还有后续内容。必须先通过源码搜索或目录树取得路径。",
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

    public static let updateProviderModels = InternalToolDefinition(
        name: "propose_provider_models_json",
        description: "在当前提供商下按模型 ID 新增或更新模型配置，并将它加入可用模型列表。只在用户明确要求删除时填写 remove_model_ids。",
        parameters: objectSchema(properties: [
            "models": .dictionary([
                "type": .string("array"),
                "description": .string("要新增或更新的模型 JSON 对象；未填写的字段在更新时保留现值"),
                "items": providerModelSchema
            ]),
            "remove_model_ids": .dictionary([
                "type": .string("array"),
                "description": .string("仅当用户明确要求删除时，列出要移除的 API 模型 ID"),
                "items": .dictionary(["type": .string("string")])
            ])
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
        description: "提出 MCP 工具箱总设置与服务器顺序修改。",
        parameters: objectSchema(properties: [
            "chat_tools_enabled": boolProperty("是否向普通聊天模型暴露 MCP 工具"),
            "tool_call_title_enabled": boolProperty("是否让 AI 生成 MCP 调用标题"),
            "server_order": GuideOrderedSettingsSupport.identifierOrderSchema
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

    public static let updateMCPServer = InternalToolDefinition(
        name: "propose_mcp_server_configuration",
        description: "提出当前 MCP Server 的修改。configuration 只在需要修改连接配置时填写；省略时保留现有连接与秘密。",
        parameters: objectSchema(properties: [
            "display_name": stringProperty("服务器显示名称"),
            "notes": stringProperty("备注，空字符串表示清除"),
            "selected_for_chat": boolProperty("是否加入普通聊天工具"),
            "configuration": .dictionary([
                "type": .string("object"),
                "description": .string("完整连接配置。HTTP/SSE/stdio 沿用 mcpServers 单项格式；OAuth 使用 type=oauth、url、tokenEndpoint、clientID、grantType，并可写入新的秘密字段。已有秘密不可读取，省略时会保留。")
            ])
        ])
    )

    public static let updateMCPTool = InternalToolDefinition(
        name: "propose_mcp_tool_configuration",
        description: "提出当前 MCP 工具的启用状态与审批策略修改。原生敏感能力固定为每次询问。",
        parameters: objectSchema(properties: [
            "enabled": boolProperty("是否启用此工具"),
            "approval_policy": .dictionary([
                "type": .string("string"),
                "enum": .array(MCPToolApprovalPolicy.allCases.map { .string($0.rawValue) }),
                "description": .string("ask_every_time、always_allow 或 always_deny")
            ])
        ])
    )

    public static let updateShortcutPreferences = InternalToolDefinition(
        name: "propose_shortcut_preferences",
        description: "提出快捷指令工具箱总设置修改。只填写确实需要变化的字段。",
        parameters: objectSchema(properties: [
            "chat_tools_enabled": boolProperty("是否向普通聊天模型暴露快捷指令工具"),
            "official_import_shortcut_name": stringProperty("官方导入快捷指令在系统中的名称"),
            "bridge_shortcut_name": stringProperty("桥接快捷指令名称")
        ])
    )

    public static let updateShortcutTool = InternalToolDefinition(
        name: "propose_shortcut_tool_configuration",
        description: "提出当前快捷指令工具的启用状态、运行模式或自定义描述修改。",
        parameters: objectSchema(properties: [
            "enabled": boolProperty("是否启用此工具"),
            "run_mode": .dictionary([
                "type": .string("string"),
                "enum": .array(ShortcutRunModeHint.allCases.map { .string($0.rawValue) }),
                "description": .string("direct 表示直连优先，bridge 表示桥接优先")
            ]),
            "user_description": stringProperty("提供给模型的自定义工具描述，空字符串表示清除")
        ])
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
        searchSourceCode,
        listSourceDirectory,
        readSourceFile
    ]

    public static func availableKnowledgeDefinitions(commitSHA: String?) -> [InternalToolDefinition] {
        guard let commitSHA, GuideBuildVersion.isFullSHA(commitSHA) else {
            return [currentPageContext, searchDocuments, readDocument]
        }
        return knowledgeDefinitions
    }

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

    private static var providerModelSchema: JSONValue {
        .dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "model_id": stringProperty("API 请求使用的模型 ID"),
                "display_name": stringProperty("App 内显示名称；空字符串表示使用模型 ID"),
                "kind": .dictionary([
                    "type": .string("string"),
                    "description": .string("模型主用途"),
                    "enum": .array(ModelKind.allCases.map { .string($0.rawValue) })
                ]),
                "picker_group": stringProperty("模型选择器分组；空字符串表示不分组"),
                "api_format_override": stringProperty("空字符串表示跟随提供商，或填写支持的 API 格式"),
                "input_modalities": stringArrayProperty(
                    description: "模型支持的输入模态；填写后整体替换",
                    values: ModelModality.allCases.map(\.rawValue)
                ),
                "output_modalities": stringArrayProperty(
                    description: "模型支持的输出模态；填写后整体替换",
                    values: ModelModality.outputCases.map(\.rawValue)
                ),
                "capabilities": stringArrayProperty(
                    description: "工具调用、推理、提示缓存等协议能力；填写后整体替换",
                    values: ModelCapability.allCases.map(\.rawValue)
                ),
                "supports_tool_calling": boolProperty("是否支持工具调用；可用于不重写 capabilities 的快速修改"),
                "request_body_json": .dictionary([
                    "type": .string("object"),
                    "description": .string("与默认请求体合并的任意 JSON 对象；填写后整体替换该模型当前覆盖")
                ])
            ]),
            "required": .array([.string("model_id")]),
            "additionalProperties": .bool(false)
        ])
    }

    private static func stringArrayProperty(description: String, values: [String]) -> JSONValue {
        .dictionary([
            "type": .string("array"),
            "description": .string(description),
            "items": .dictionary([
                "type": .string("string"),
                "enum": .array(values.map(JSONValue.string))
            ]),
            "uniqueItems": .bool(true)
        ])
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

public struct GuideProviderModelsApplication {
    public let provider: Provider
    public let undoProposal: GuideActionProposal?

    public init(provider: Provider, undoProposal: GuideActionProposal?) {
        self.provider = provider
        self.undoProposal = undoProposal
    }
}

/// 提供商模型列表的向导写入边界：AI 只提交结构化变更，客户端校验、预览并保留完整撤销快照。
public enum GuideProviderModelsProposalSupport {
    private static let restoreToolName = "restore_provider_models_after_guide_change"
    private static let allowedRootKeys: Set<String> = ["models", "remove_model_ids"]
    private static let allowedModelKeys: Set<String> = [
        "model_id",
        "display_name",
        "kind",
        "picker_group",
        "api_format_override",
        "input_modalities",
        "output_modalities",
        "capabilities",
        "supports_tool_calling",
        "request_body_json"
    ]
    private static let supportedAPIFormats: Set<String> = [
        "",
        "openai-compatible",
        "openai-responses",
        "gemini",
        "anthropic"
    ]

    private struct ModelDraft {
        let modelID: String
        let displayName: String?
        let hasDisplayName: Bool
        let kind: ModelKind?
        let pickerGroup: String?
        let hasPickerGroup: Bool
        let apiFormatOverride: String?
        let hasAPIFormatOverride: Bool
        let inputModalities: [ModelModality]?
        let outputModalities: [ModelModality]?
        let capabilities: [ModelCapability]?
        let supportsToolCalling: Bool?
        let requestBody: [String: JSONValue]?
    }

    private struct DecodedChanges {
        let drafts: [ModelDraft]
        let removedModelIDs: [String]
    }

    public static func snapshotValue(for models: [Model]) -> JSONValue {
        .array(models.filter(\.isActivated).map(modelValue))
    }

    public static func buildProposal(
        call: InternalToolCall,
        pageID: GuidePageID,
        provider: Provider
    ) throws -> GuideActionProposal {
        guard call.toolName == GuideToolCatalog.updateProviderModels.name else {
            throw GuideError.unsupportedTool(call.toolName)
        }
        let arguments = try GuideToolArguments.decode(call.arguments)
        let changes = try decodeChanges(arguments)
        let updated = try applying(changes, to: provider)
        let touchedModelIDs = changes.drafts.map(\.modelID) + changes.removedModelIDs
        let mutations = touchedModelIDs.compactMap { modelID -> GuideSettingMutation? in
            let oldModel = provider.models.first { $0.modelName == modelID }
            let newModel = updated.models.first { $0.modelName == modelID }
            guard oldModel != newModel else { return nil }
            return GuideSettingMutation(
                path: "models.\(modelID)",
                label: newModel?.displayName ?? oldModel?.displayName ?? modelID,
                oldValue: oldModel.map(modelValue),
                newValue: newModel.map(modelValue) ?? .null
            )
        }
        guard !mutations.isEmpty else { throw GuideError.invalidToolArguments }

        let summaryFormat = GuideSecretRedactor.containsSensitiveField(.dictionary(arguments))
            ? NSLocalizedString(
                "新增或更新 %d 个模型，移除 %d 个模型（包含疑似认证字段，请仔细确认）",
                comment: "包含敏感字段的提供商模型向导提案摘要"
            )
            : NSLocalizedString("新增或更新 %d 个模型，移除 %d 个模型", comment: "提供商模型向导提案摘要")
        let summary = String(
            format: summaryFormat,
            changes.drafts.count,
            changes.removedModelIDs.count
        )
        return GuideActionProposal(
            pageID: pageID,
            toolCallID: call.id,
            toolName: call.toolName,
            summary: summary,
            mutations: mutations,
            arguments: arguments
        )
    }

    public static func apply(
        _ proposal: GuideActionProposal,
        to provider: Provider
    ) throws -> GuideProviderModelsApplication {
        if proposal.toolName == restoreToolName {
            try GuideToolArguments.requireOnlyKeys(["models"], in: proposal.arguments)
            guard let value = proposal.arguments["models"] else { throw GuideError.invalidToolArguments }
            var restored = provider
            restored.models = try decodeModels(value)
            return GuideProviderModelsApplication(provider: restored, undoProposal: nil)
        }
        guard proposal.toolName == GuideToolCatalog.updateProviderModels.name else {
            throw GuideError.unsupportedTool(proposal.toolName)
        }

        let changes = try decodeChanges(proposal.arguments)
        let updated = try applying(changes, to: provider)
        let undo = GuideActionProposal(
            pageID: proposal.pageID,
            toolCallID: "undo-\(proposal.toolCallID)",
            toolName: restoreToolName,
            summary: NSLocalizedString("撤销向导的模型列表修改", comment: "提供商模型向导撤销摘要"),
            mutations: [],
            arguments: ["models": try encodedModels(provider.models)]
        )
        return GuideProviderModelsApplication(provider: updated, undoProposal: undo)
    }

    private static func decodeChanges(_ arguments: [String: JSONValue]) throws -> DecodedChanges {
        try GuideToolArguments.requireOnlyKeys(allowedRootKeys, in: arguments)
        let draftValues: [JSONValue]
        if let value = arguments["models"] {
            guard case .array(let values) = value else { throw GuideError.invalidToolArguments }
            draftValues = values
        } else {
            draftValues = []
        }
        let removedModelIDs = try stringArray("remove_model_ids", in: arguments) ?? []
        let drafts = try draftValues.map(decodeDraft)
        guard !drafts.isEmpty || !removedModelIDs.isEmpty else { throw GuideError.invalidToolArguments }

        let draftIDs = drafts.map(\.modelID)
        guard Set(draftIDs).count == draftIDs.count,
              Set(removedModelIDs).count == removedModelIDs.count,
              Set(draftIDs).isDisjoint(with: removedModelIDs) else {
            throw GuideError.invalidToolArguments
        }
        return DecodedChanges(drafts: drafts, removedModelIDs: removedModelIDs)
    }

    private static func decodeDraft(_ value: JSONValue) throws -> ModelDraft {
        guard case .dictionary(let values) = value else { throw GuideError.invalidToolArguments }
        try GuideToolArguments.requireOnlyKeys(allowedModelKeys, in: values)
        let modelID = try GuideToolArguments.string("model_id", in: values)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { throw GuideError.invalidToolArguments }

        let kind: ModelKind?
        if let rawKind = try GuideToolArguments.optionalString("kind", in: values) {
            guard let parsed = ModelKind(rawValue: rawKind), ModelKind.allCases.contains(parsed) else {
                throw GuideError.invalidToolArguments
            }
            kind = parsed
        } else {
            kind = nil
        }

        let apiFormat = try GuideToolArguments.optionalString("api_format_override", in: values)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let apiFormat, !supportedAPIFormats.contains(apiFormat) {
            throw GuideError.invalidToolArguments
        }

        let inputModalities = try enumArray(
            "input_modalities",
            in: values,
            transform: ModelModality.init(rawValue:)
        )
        let outputModalities = try enumArray(
            "output_modalities",
            in: values,
            transform: ModelModality.init(rawValue:)
        )
        if let outputModalities,
           outputModalities.contains(where: { !ModelModality.outputCases.contains($0) }) {
            throw GuideError.invalidToolArguments
        }
        let capabilities = try enumArray(
            "capabilities",
            in: values,
            transform: ModelCapability.init(rawValue:)
        )

        let requestBody: [String: JSONValue]?
        if let value = values["request_body_json"] {
            guard case .dictionary(let body) = value else { throw GuideError.invalidToolArguments }
            requestBody = body
        } else {
            requestBody = nil
        }

        return ModelDraft(
            modelID: modelID,
            displayName: try GuideToolArguments.optionalString("display_name", in: values),
            hasDisplayName: values["display_name"] != nil,
            kind: kind,
            pickerGroup: try GuideToolArguments.optionalString("picker_group", in: values),
            hasPickerGroup: values["picker_group"] != nil,
            apiFormatOverride: apiFormat,
            hasAPIFormatOverride: values["api_format_override"] != nil,
            inputModalities: inputModalities,
            outputModalities: outputModalities,
            capabilities: capabilities,
            supportsToolCalling: try GuideToolArguments.optionalBool("supports_tool_calling", in: values),
            requestBody: requestBody
        )
    }

    private static func applying(_ changes: DecodedChanges, to provider: Provider) throws -> Provider {
        var updated = provider
        for removedID in changes.removedModelIDs {
            guard updated.models.contains(where: { $0.modelName == removedID }) else {
                throw GuideError.invalidToolArguments
            }
            updated.models.removeAll { $0.modelName == removedID }
        }

        for draft in changes.drafts {
            let existingIndex = updated.models.firstIndex { $0.modelName == draft.modelID }
            var model = existingIndex.map { updated.models[$0] }
                ?? Model.inferred(modelName: draft.modelID, isActivated: true)
            if let kind = draft.kind, kind != model.kind {
                model.resetCapabilityShape(for: kind)
            }
            model.modelName = draft.modelID
            model.isActivated = true
            if draft.hasDisplayName {
                let normalized = draft.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                model.displayName = normalized.isEmpty ? draft.modelID : normalized
            }
            if draft.hasPickerGroup {
                model.pickerGroupName = Model.normalizedPickerGroupName(draft.pickerGroup)
            }
            if draft.hasAPIFormatOverride {
                model.apiFormatOverride = Model.normalizedAPIFormatOverride(draft.apiFormatOverride)
            }
            if let inputModalities = draft.inputModalities {
                model.inputModalities = Model.orderedModalities(inputModalities)
            }
            if let outputModalities = draft.outputModalities {
                model.outputModalities = Model.orderedOutputModalities(outputModalities)
            }
            if let capabilities = draft.capabilities {
                model.capabilities = Model.orderedCapabilities(capabilities)
            }
            if let supportsToolCalling = draft.supportsToolCalling {
                var capabilities = Set(model.capabilities)
                if supportsToolCalling {
                    guard model.kind == .chat else { throw GuideError.invalidToolArguments }
                    capabilities.insert(.toolCalling)
                } else {
                    capabilities.remove(.toolCalling)
                }
                model.capabilities = Model.orderedCapabilities(Array(capabilities))
            }
            if model.inputModalities.contains(.video),
               model.effectiveAPIFormat(providerAPIFormat: updated.apiFormat) != "gemini" {
                throw GuideError.invalidToolArguments
            }
            if let requestBody = draft.requestBody {
                model.overrideParameters = requestBody
                model.requestBodyOverrideMode = .rawJSON
                model.rawRequestBodyJSON = JSONValue.dictionary(requestBody).prettyPrintedCompact()
            }

            if let existingIndex {
                updated.models[existingIndex] = model
            } else {
                updated.models.append(model)
            }
        }
        return updated
    }

    private static func modelValue(_ model: Model) -> JSONValue {
        GuideSecretRedactor.redact(.dictionary([
            "model_id": .string(model.modelName),
            "display_name": .string(model.displayName),
            "activated": .bool(model.isActivated),
            "kind": .string(model.kind.rawValue),
            "picker_group": .string(model.pickerGroupName ?? ""),
            "api_format_override": .string(model.apiFormatOverride ?? ""),
            "input_modalities": .array(model.inputModalities.map { .string($0.rawValue) }),
            "output_modalities": .array(model.outputModalities.map { .string($0.rawValue) }),
            "capabilities": .array(model.capabilities.map { .string($0.rawValue) }),
            "request_body_json": .dictionary(model.overrideParameters)
        ]))
    }

    private static func stringArray(
        _ key: String,
        in arguments: [String: JSONValue]
    ) throws -> [String]? {
        guard let value = arguments[key] else { return nil }
        guard case .array(let values) = value else { throw GuideError.invalidToolArguments }
        return try values.map { value in
            guard case .string(let string) = value else { throw GuideError.invalidToolArguments }
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { throw GuideError.invalidToolArguments }
            return normalized
        }
    }

    private static func enumArray<Value>(
        _ key: String,
        in arguments: [String: JSONValue],
        transform: (String) -> Value?
    ) throws -> [Value]? where Value: Hashable {
        guard let values = try stringArray(key, in: arguments) else { return nil }
        let transformed = try values.map { rawValue in
            guard let value = transform(rawValue) else { throw GuideError.invalidToolArguments }
            return value
        }
        guard Set(transformed).count == transformed.count else { throw GuideError.invalidToolArguments }
        return transformed
    }

    private static func encodedModels(_ models: [Model]) throws -> JSONValue {
        let data = try JSONEncoder().encode(models)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func decodeModels(_ value: JSONValue) throws -> [Model] {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode([Model].self, from: data)
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
