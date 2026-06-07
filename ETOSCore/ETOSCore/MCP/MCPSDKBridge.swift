// ============================================================================
// MCPSDKBridge.swift
// ============================================================================
// ETOS LLM Studio
//
// 将官方 MCP Swift SDK 的模型转换为应用内部稳定使用的 MCP 数据结构。
// ============================================================================

import Foundation
import MCP

enum MCPSDKBridge {
    static func value(from jsonValue: JSONValue) -> Value {
        switch jsonValue {
        case .string(let value):
            return .string(value)
        case .int(let value):
            return .int(value)
        case .double(let value):
            return .double(value)
        case .bool(let value):
            return .bool(value)
        case .dictionary(let value):
            return .object(value.mapValues { Self.value(from: $0) })
        case .array(let value):
            return .array(value.map { Self.value(from: $0) })
        case .null:
            return .null
        }
    }

    static func jsonValue(from value: Value) -> JSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .int(let value):
            return .int(value)
        case .double(let value):
            return .double(value)
        case .string(let value):
            return .string(value)
        case .data(let mimeType, let data):
            let prefix = mimeType.map { "data:\($0);base64," } ?? "data:;base64,"
            return .string(prefix + data.base64EncodedString())
        case .array(let values):
            return .array(values.map { jsonValue(from: $0) })
        case .object(let values):
            return .dictionary(values.mapValues { jsonValue(from: $0) })
        }
    }

    static func metadata(from values: [String: JSONValue]) -> Metadata {
        Metadata(additionalFields: values.mapValues { value(from: $0) })
    }

    static func jsonValues(from metadata: Metadata?) -> [String: JSONValue]? {
        guard let metadata else { return nil }
        return metadata.fields.mapValues { jsonValue(from: $0) }
    }

    static func progressToken(from token: MCPProgressToken?) -> ProgressToken? {
        guard let token else { return nil }
        switch token {
        case .string(let value):
            return .string(value)
        case .int(let value):
            return .integer(value)
        }
    }

    static func progressToken(from token: ProgressToken) -> MCPProgressToken {
        switch token {
        case .string(let value):
            return .string(value)
        case .integer(let value):
            return .int(value)
        }
    }

    static func clientCapabilities(from capabilities: MCPClientCapabilities) -> Client.Capabilities {
        Client.Capabilities(
            sampling: capabilities.sampling == nil ? nil : Client.Capabilities.Sampling(),
            elicitation: capabilities.elicitation == nil ? nil : Client.Capabilities.Elicitation(
                form: capabilities.elicitation?.form == nil ? nil : Client.Capabilities.Elicitation.Form(),
                url: capabilities.elicitation?.url == nil ? nil : Client.Capabilities.Elicitation.URL()
            ),
            experimental: stringExperimentalCapabilities(from: capabilities.experimental),
            roots: capabilities.roots.map { Client.Capabilities.Roots(listChanged: $0.listChanged) }
        )
    }

    static func serverInfo(from result: Initialize.Result) -> MCPServerInfo {
        MCPServerInfo(
            name: result.serverInfo.name,
            version: result.serverInfo.version,
            capabilities: jsonDictionary(from: result.capabilities),
            metadata: jsonValues(from: result._meta)
        )
    }

    static func toolDescription(from tool: Tool) -> MCPToolDescription {
        MCPToolDescription(
            toolId: tool.name,
            description: tool.description,
            inputSchema: jsonValue(from: tool.inputSchema),
            examples: nil
        )
    }

    static func resourceDescription(from resource: Resource) -> MCPResourceDescription {
        MCPResourceDescription(
            resourceId: resource.uri,
            description: resource.description,
            outputSchema: nil,
            querySchema: nil
        )
    }

    static func resourceTemplate(from template: Resource.Template) -> MCPResourceTemplate {
        MCPResourceTemplate(
            uriTemplate: template.uriTemplate,
            name: template.name,
            title: template.title,
            description: template.description,
            mimeType: template.mimeType,
            annotations: template.annotations.map { jsonValue(fromEncodable: $0) },
            metadata: jsonValues(from: template._meta)
        )
    }

    static func promptDescription(from prompt: Prompt) -> MCPPromptDescription {
        MCPPromptDescription(
            name: prompt.name,
            description: prompt.description,
            arguments: prompt.arguments?.map {
                MCPPromptArgument(
                    name: $0.name,
                    description: $0.description,
                    required: $0.required
                )
            }
        )
    }

    static func promptResult(description: String?, messages: [Prompt.Message]) -> MCPGetPromptResult {
        MCPGetPromptResult(
            description: description,
            messages: messages.map {
                MCPPromptMessage(
                    role: $0.role.rawValue,
                    content: promptContent(from: $0.content)
                )
            }
        )
    }

    static func root(from root: Root) -> MCPRoot {
        MCPRoot(uri: root.uri, name: root.name)
    }

    static func completionReference(from reference: MCPCompletionReference) -> CompletionReference {
        switch reference {
        case .prompt(let name):
            return .prompt(.init(name: name))
        case .resource(let uri):
            return .resource(.init(uri: uri))
        }
    }

    static func logLevel(from level: MCPLogLevel) -> LogLevel {
        LogLevel(rawValue: level.rawValue) ?? .info
    }

    static func logLevel(from level: LogLevel) -> MCPLogLevel {
        MCPLogLevel(rawValue: level.rawValue) ?? .info
    }

    static func progressParams(from params: ProgressNotification.Parameters) -> MCPProgressParams {
        MCPProgressParams(
            progressToken: progressToken(from: params.progressToken),
            progress: params.progress,
            total: params.total
        )
    }

    static func logEntry(from params: LogMessageNotification.Parameters) -> MCPLogEntry {
        MCPLogEntry(
            level: logLevel(from: params.level),
            logger: params.logger,
            data: jsonValue(from: params.data)
        )
    }

    static func samplingRequest(from params: CreateSamplingMessage.Parameters) -> MCPSamplingRequest {
        MCPSamplingRequest(
            messages: params.messages.map { message in
                MCPSamplingMessage(
                    role: message.role.rawValue,
                    content: samplingContent(from: message.content)
                )
            },
            modelPreferences: params.modelPreferences.map { preferences in
                MCPModelPreferences(
                    hints: preferences.hints?.map { MCPModelHint(name: $0.name) },
                    costPriority: preferences.costPriority?.doubleValue,
                    speedPriority: preferences.speedPriority?.doubleValue,
                    intelligencePriority: preferences.intelligencePriority?.doubleValue
                )
            },
            systemPrompt: params.systemPrompt,
            includeContext: params.includeContext?.rawValue,
            temperature: params.temperature,
            maxTokens: params.maxTokens,
            stopSequences: params.stopSequences,
            metadata: params.metadata?.mapValues { jsonValue(from: $0) }
        )
    }

    static func samplingResult(from response: MCPSamplingResponse) -> CreateSamplingMessage.Result {
        CreateSamplingMessage.Result(
            model: response.model,
            stopReason: response.stopReason.map { Sampling.StopReason(rawValue: $0) },
            role: Sampling.Message.Role(rawValue: response.role) ?? .assistant,
            content: samplingContent(from: response.content)
        )
    }

    static func elicitationRequest(from params: CreateElicitation.Parameters) -> MCPElicitationRequest {
        switch params {
        case .form(let form):
            return .form(
                MCPFormElicitationRequest(
                    message: form.message,
                    requestedSchema: requestedSchema(from: form.requestedSchema),
                    metadata: requestMeta(from: form._meta)
                )
            )
        case .url(let url):
            return .url(
                MCPURLElicitationRequest(
                    message: url.message,
                    elicitationId: url.elicitationId,
                    url: url.url,
                    metadata: requestMeta(from: url._meta)
                )
            )
        }
    }

    static func elicitationResult(from response: MCPElicitationResult) -> CreateElicitation.Result {
        CreateElicitation.Result(
            action: CreateElicitation.Result.Action(rawValue: response.action.rawValue) ?? .decline,
            content: response.content?.mapValues { value(from: $0) }
        )
    }

    static func notification(method: String, params: JSONValue? = nil) -> MCPNotification {
        MCPNotification(jsonrpc: "2.0", method: method, params: params)
    }

    static func jsonValue<Result: Encodable>(fromToolResult result: Result) throws -> JSONValue {
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func promptContent(from content: Prompt.Message.Content) -> MCPPromptContent {
        switch content {
        case .text(let text):
            return .text(text)
        case .image(let data, let mimeType):
            return .image(data: data, mimeType: mimeType)
        case .audio(let data, let mimeType):
            return .resource(uri: "audio://inline", mimeType: mimeType, text: data)
        case .resource(let resource, _, _):
            return .resource(uri: resource.uri, mimeType: resource.mimeType, text: resource.text ?? resource.blob)
        case .resourceLink(let uri, _, _, _, let mimeType, _):
            return .resource(uri: uri, mimeType: mimeType, text: nil)
        }
    }

    private static func samplingContent(from content: Sampling.Message.Content) -> MCPSamplingContent {
        let blocks = content.asArray
        guard blocks.count == 1, let block = blocks.first else {
            return .text(jsonValue(fromEncodable: blocks).prettyPrintedCompact())
        }
        switch block {
        case .text(let text):
            return .text(text)
        case .image(let data, let mimeType):
            return .image(data: data, mimeType: mimeType)
        case .audio(_, _), .toolUse(_), .toolResult(_):
            return .text(jsonValue(fromEncodable: block).prettyPrintedCompact())
        }
    }

    private static func samplingContent(from content: MCPSamplingContent) -> Sampling.Message.Content {
        switch content {
        case .text(let text):
            return .text(text)
        case .image(let data, let mimeType):
            return .image(data: data, mimeType: mimeType)
        }
    }

    private static func requestedSchema(from schema: Elicitation.RequestSchema) -> MCPElicitationRequestedSchema {
        MCPElicitationRequestedSchema(
            type: schema.type.rawValue,
            properties: schema.properties.mapValues { jsonValue(from: $0) },
            required: schema.required
        )
    }

    private static func requestMeta(from metadata: Metadata?) -> MCPElicitationRequestMeta? {
        guard let progressToken = metadata?.progressToken else { return nil }
        return MCPElicitationRequestMeta(progressToken: Self.progressToken(from: progressToken))
    }

    private static func jsonDictionary<T: Encodable>(from value: T) -> [String: JSONValue]? {
        guard case let .dictionary(dictionary) = jsonValue(fromEncodable: value) else {
            return nil
        }
        return dictionary
    }

    private static func jsonValue<T: Encodable>(fromEncodable value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return decoded
    }

    private static func stringExperimentalCapabilities(from experimental: [String: JSONValue]?) -> [String: String]? {
        guard let experimental else { return nil }
        var result: [String: String] = [:]
        for (key, value) in experimental {
            switch value {
            case .string(let stringValue):
                result[key] = stringValue
            default:
                result[key] = value.prettyPrintedCompact()
            }
        }
        return result
    }
}
