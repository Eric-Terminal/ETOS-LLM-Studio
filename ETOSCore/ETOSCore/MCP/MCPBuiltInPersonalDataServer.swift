// ============================================================================
// MCPBuiltInPersonalDataServer.swift
// ============================================================================
// ETOS LLM Studio
//
// 将 HealthKit 与 EventKit 能力包装为内建 MCP Server。
// 这里只公布工具清单；真正读取或写入数据时才触发系统权限请求。
// ============================================================================

import Foundation
import Logging
import MCP

public enum MCPBuiltInPersonalDataServer {
    public static let serverID = UUID(uuidString: "45544F53-0000-0000-0000-504452534E4C")!
    public static let endpoint = "builtin://personal-data"

    public static let toolIDs = [
        "health.list_types",
        "health.query_samples",
        "health.query_statistics",
        "health.write_quantity",
        "health.write_category",
        "calendar.query_events",
        "calendar.create_event",
        "calendar.update_event",
        "calendar.delete_event",
        "reminder.query_reminders",
        "reminder.create_reminder",
        "reminder.update_reminder",
        "reminder.delete_reminder"
    ]

    public static func isBuiltInPersonalDataServer(_ server: MCPServerConfiguration) -> Bool {
        server.id == serverID || server.transport == .builtInPersonalData
    }

    static func defaultConfiguration() -> MCPServerConfiguration {
        MCPServerConfiguration(
            id: serverID,
            displayName: NSLocalizedString("内建个人数据", comment: "Built-in personal data MCP server name"),
            notes: NSLocalizedString("提供 HealthKit 健康数据与 EventKit 日历/提醒事项工具。仅在工具正式调用时申请系统权限。", comment: "Built-in personal data MCP server notes"),
            transport: .builtInPersonalData,
            isSelectedForChat: true,
            sortIndex: 100
        )
    }

    static func prepareServersForManager(_ storedServers: [MCPServerConfiguration]) -> (
        servers: [MCPServerConfiguration],
        serverToPersist: MCPServerConfiguration?
    ) {
        var servers = storedServers
        let defaultServer = defaultConfiguration()
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else {
            servers.append(defaultServer)
            return (servers, defaultServer)
        }

        var server = servers[index]
        var shouldPersist = false
        if server.transport != .builtInPersonalData {
            server.transport = .builtInPersonalData
            shouldPersist = true
        }
        if server.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            server.displayName = defaultServer.displayName
            shouldPersist = true
        }
        servers[index] = server
        return (servers, shouldPersist ? server : nil)
    }

    static func toolDescriptions() -> [MCPToolDescription] {
        [
            MCPToolDescription(
                toolId: "health.list_types",
                description: NSLocalizedString("列出当前内建 HealthKit 工具支持的健康数据类型、读写能力与默认单位。不会请求 HealthKit 权限。", comment: ""),
                inputSchema: objectSchema(properties: [:])
            ),
            MCPToolDescription(
                toolId: "health.query_samples",
                description: NSLocalizedString("按 HealthKit 类型读取原始样本，例如 heart_rate、heart_rate_variability、sleep_analysis、workouts、body_mass。调用时仅请求所需类型的读取权限。", comment: ""),
                inputSchema: objectSchema(
                    properties: [
                        "type": stringSchema(NSLocalizedString("HealthKit 类型名，可先调用 health.list_types 查看。", comment: "")),
                        "start_date": stringSchema(NSLocalizedString("ISO-8601 开始时间。", comment: "")),
                        "end_date": stringSchema(NSLocalizedString("ISO-8601 结束时间。", comment: "")),
                        "limit": integerSchema(NSLocalizedString("最大样本数，默认 100，最大 500。", comment: ""), minimum: 1, maximum: 500)
                    ],
                    required: ["type", "start_date", "end_date"]
                )
            ),
            MCPToolDescription(
                toolId: "health.query_statistics",
                description: NSLocalizedString("按 HealthKit 数值类型读取统计结果，适合步数、活动能量、心率均值、HRV 均值等汇总查询。调用时仅请求所需类型的读取权限。", comment: ""),
                inputSchema: objectSchema(
                    properties: [
                        "type": stringSchema(NSLocalizedString("HealthKit 数值类型名。", comment: "")),
                        "start_date": stringSchema(NSLocalizedString("ISO-8601 开始时间。", comment: "")),
                        "end_date": stringSchema(NSLocalizedString("ISO-8601 结束时间。", comment: "")),
                        "aggregation": enumSchema(
                            NSLocalizedString("统计方式：sum、average、min、max。省略时按类型自动选择。", comment: ""),
                            values: ["sum", "average", "min", "max"]
                        )
                    ],
                    required: ["type", "start_date", "end_date"]
                )
            ),
            MCPToolDescription(
                toolId: "health.write_quantity",
                description: NSLocalizedString("写入允许记录的 HealthKit 数值样本，例如 dietary_water、dietary_caffeine、dietary_energy、body_mass。调用时仅请求该类型写入权限。", comment: ""),
                inputSchema: objectSchema(
                    properties: [
                        "type": stringSchema(NSLocalizedString("可写 HealthKit 数值类型名。", comment: "")),
                        "value": numberSchema(NSLocalizedString("要写入的数值，使用类型默认单位。", comment: "")),
                        "start_date": stringSchema(NSLocalizedString("ISO-8601 开始时间；省略时使用当前时间。", comment: "")),
                        "end_date": stringSchema(NSLocalizedString("ISO-8601 结束时间；省略时等于开始时间。", comment: "")),
                        "note": stringSchema(NSLocalizedString("可选备注，会写入 HealthKit 元数据。", comment: ""))
                    ],
                    required: ["type", "value"]
                )
            ),
            MCPToolDescription(
                toolId: "health.write_category",
                description: NSLocalizedString("写入允许记录的 HealthKit 分类样本，例如 mindful_session、headache、fever、coughing。调用时仅请求该类型写入权限。", comment: ""),
                inputSchema: objectSchema(
                    properties: [
                        "type": stringSchema(NSLocalizedString("可写 HealthKit 分类类型名。", comment: "")),
                        "value": stringSchema(NSLocalizedString("分类值；症状支持 not_present、mild、moderate、severe，正念可省略。", comment: "")),
                        "start_date": stringSchema(NSLocalizedString("ISO-8601 开始时间；省略时使用当前时间。", comment: "")),
                        "end_date": stringSchema(NSLocalizedString("ISO-8601 结束时间；省略时可用 duration_minutes。", comment: "")),
                        "duration_minutes": numberSchema(NSLocalizedString("持续分钟数，适合正念或症状记录。", comment: "")),
                        "note": stringSchema(NSLocalizedString("可选备注，会写入 HealthKit 元数据。", comment: ""))
                    ],
                    required: ["type"]
                )
            ),
            MCPToolDescription(
                toolId: "calendar.query_events",
                description: NSLocalizedString("查询指定时间段内的系统日历事件，包含标题、地点、起止时间、备注和参与人摘要。调用时请求日历完整访问权限。", comment: ""),
                inputSchema: objectSchema(
                    properties: [
                        "start_date": stringSchema(NSLocalizedString("ISO-8601 开始时间。", comment: "")),
                        "end_date": stringSchema(NSLocalizedString("ISO-8601 结束时间。", comment: "")),
                        "calendar_id": stringSchema(NSLocalizedString("可选日历 ID。", comment: ""))
                    ],
                    required: ["start_date", "end_date"]
                )
            ),
            MCPToolDescription(
                toolId: "calendar.create_event",
                description: NSLocalizedString("创建系统日历事件，可设置地点、备注、提醒和简单循环规则。iOS 可写，watchOS 返回不支持。", comment: ""),
                inputSchema: calendarEventWriteSchema(required: ["title", "start_date", "end_date"])
            ),
            MCPToolDescription(
                toolId: "calendar.update_event",
                description: NSLocalizedString("更新已有系统日历事件。iOS 可写，watchOS 返回不支持。", comment: ""),
                inputSchema: calendarEventWriteSchema(required: ["event_id"])
            ),
            MCPToolDescription(
                toolId: "calendar.delete_event",
                description: NSLocalizedString("删除已有系统日历事件。iOS 可写，watchOS 返回不支持。", comment: ""),
                inputSchema: objectSchema(
                    properties: [
                        "event_id": stringSchema(NSLocalizedString("事件 ID。", comment: "")),
                        "future_events": boolSchema(NSLocalizedString("删除循环事件时是否影响未来事件。", comment: ""))
                    ],
                    required: ["event_id"]
                )
            ),
            MCPToolDescription(
                toolId: "reminder.query_reminders",
                description: NSLocalizedString("查询系统提醒事项，可按列表、完成状态和截止时间过滤。调用时请求提醒事项完整访问权限。", comment: ""),
                inputSchema: objectSchema(
                    properties: [
                        "calendar_id": stringSchema(NSLocalizedString("可选提醒事项列表 ID。", comment: "")),
                        "completed": boolSchema(NSLocalizedString("是否只返回已完成/未完成事项；省略则返回全部。", comment: "")),
                        "start_date": stringSchema(NSLocalizedString("可选截止时间开始。", comment: "")),
                        "end_date": stringSchema(NSLocalizedString("可选截止时间结束。", comment: ""))
                    ]
                )
            ),
            MCPToolDescription(
                toolId: "reminder.create_reminder",
                description: NSLocalizedString("创建系统提醒事项，可设置截止时间、优先级、时间提醒或位置提醒。iOS 可写，watchOS 返回不支持。", comment: ""),
                inputSchema: reminderWriteSchema(required: ["title"])
            ),
            MCPToolDescription(
                toolId: "reminder.update_reminder",
                description: NSLocalizedString("更新已有系统提醒事项，可修改完成状态、截止时间、优先级和提醒。iOS 可写，watchOS 返回不支持。", comment: ""),
                inputSchema: reminderWriteSchema(required: ["reminder_id"])
            ),
            MCPToolDescription(
                toolId: "reminder.delete_reminder",
                description: NSLocalizedString("删除已有系统提醒事项。iOS 可写，watchOS 返回不支持。", comment: ""),
                inputSchema: objectSchema(
                    properties: [
                        "reminder_id": stringSchema(NSLocalizedString("提醒事项 ID。", comment: ""))
                    ],
                    required: ["reminder_id"]
                )
            )
        ]
    }

    static func objectSchema(
        properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .dictionary(properties),
            "additionalProperties": .bool(false)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .dictionary(schema)
    }

    static func stringSchema(_ description: String) -> JSONValue {
        .dictionary(["type": .string("string"), "description": .string(description)])
    }

    static func numberSchema(_ description: String) -> JSONValue {
        .dictionary(["type": .string("number"), "description": .string(description)])
    }

    static func integerSchema(_ description: String, minimum: Int, maximum: Int) -> JSONValue {
        .dictionary([
            "type": .string("integer"),
            "description": .string(description),
            "minimum": .int(minimum),
            "maximum": .int(maximum)
        ])
    }

    static func boolSchema(_ description: String) -> JSONValue {
        .dictionary(["type": .string("boolean"), "description": .string(description)])
    }

    static func enumSchema(_ description: String, values: [String]) -> JSONValue {
        .dictionary([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(values.map { .string($0) })
        ])
    }

    private static func calendarEventWriteSchema(required: [String]) -> JSONValue {
        objectSchema(
            properties: [
                "event_id": stringSchema(NSLocalizedString("更新时使用的事件 ID。", comment: "")),
                "title": stringSchema(NSLocalizedString("事件标题。", comment: "")),
                "start_date": stringSchema(NSLocalizedString("ISO-8601 开始时间。", comment: "")),
                "end_date": stringSchema(NSLocalizedString("ISO-8601 结束时间。", comment: "")),
                "calendar_id": stringSchema(NSLocalizedString("可选日历 ID。", comment: "")),
                "location": stringSchema(NSLocalizedString("地点标题或地址。", comment: "")),
                "notes": stringSchema(NSLocalizedString("备注。", comment: "")),
                "alarm_minutes_before": numberSchema(NSLocalizedString("提前多少分钟提醒。", comment: "")),
                "recurrence": enumSchema(NSLocalizedString("简单循环规则。", comment: ""), values: ["daily", "weekly", "monthly", "yearly"])
            ],
            required: required
        )
    }

    private static func reminderWriteSchema(required: [String]) -> JSONValue {
        objectSchema(
            properties: [
                "reminder_id": stringSchema(NSLocalizedString("更新时使用的提醒事项 ID。", comment: "")),
                "title": stringSchema(NSLocalizedString("标题。", comment: "")),
                "notes": stringSchema(NSLocalizedString("备注。", comment: "")),
                "calendar_id": stringSchema(NSLocalizedString("可选提醒事项列表 ID。", comment: "")),
                "due_date": stringSchema(NSLocalizedString("ISO-8601 截止时间。", comment: "")),
                "completed": boolSchema(NSLocalizedString("是否已完成。", comment: "")),
                "priority": enumSchema(NSLocalizedString("优先级。", comment: ""), values: ["none", "low", "medium", "high"]),
                "alarm_date": stringSchema(NSLocalizedString("ISO-8601 时间提醒。", comment: "")),
                "location_title": stringSchema(NSLocalizedString("位置提醒地点名称。", comment: "")),
                "latitude": numberSchema(NSLocalizedString("位置提醒纬度。", comment: "")),
                "longitude": numberSchema(NSLocalizedString("位置提醒经度。", comment: "")),
                "radius_meters": numberSchema(NSLocalizedString("位置提醒半径，单位米。", comment: "")),
                "proximity": enumSchema(NSLocalizedString("位置提醒触发方式。", comment: ""), values: ["enter", "leave"])
            ],
            required: required
        )
    }
}

public actor MCPBuiltInPersonalDataTransport: Transport, MCPSDKTransportControl {
    private let engine = MCPBuiltInPersonalDataServerEngine()
    private let loggerInstance = Logger(
        label: "etos.mcp.transport.builtin-personal-data",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var connected = false
    private var protocolVersion: String?

    public nonisolated var logger: Logger { loggerInstance }

    public init() {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    public func connect() async throws {
        connected = true
    }

    public func disconnect() async {
        guard connected else { return }
        connected = false
        continuation.finish()
    }

    public nonisolated func disconnect() {
        Task {
            await self.disconnect()
        }
    }

    public func send(_ data: Data) async throws {
        guard connected else {
            throw MCPClientError.notConnected
        }
        if isJSONRPCMessageWithoutExpectedResponse(data) {
            try await engine.handleNotification(data)
            return
        }
        let response = try await engine.handleMessage(data)
        continuation.yield(response)
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    public func currentResumptionToken() async -> String? {
        nil
    }

    public func updateResumptionToken(_ token: String?) async {}

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        self.protocolVersion = protocolVersion
    }

    public func terminateSession() async {
        await disconnect()
    }
}

public final class MCPBuiltInPersonalDataLegacyTransport: MCPTransport, MCPProtocolVersionConfigurableTransport, @unchecked Sendable {
    private let engine = MCPBuiltInPersonalDataServerEngine()
    private var protocolVersion: String?

    public init() {}

    public func sendMessage(_ payload: Data) async throws -> Data {
        try await engine.handleMessage(payload)
    }

    public func sendNotification(_ payload: Data) async throws {
        try await engine.handleNotification(payload)
    }

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        self.protocolVersion = protocolVersion
    }
}

actor MCPBuiltInPersonalDataServerEngine {
    private let jsonrpcVersion = "2.0"
    private let healthExecutor = MCPBuiltInPersonalDataHealthExecutor()
    private let eventExecutor = MCPBuiltInPersonalDataEventKitExecutor()

    func handleNotification(_ payload: Data) async throws {
        _ = try requestObject(from: payload)
    }

    func handleMessage(_ payload: Data) async throws -> Data {
        let request = try requestObject(from: payload)
        guard let id = request["id"] else {
            throw MCPClientError.invalidResponse
        }
        guard let method = request["method"] as? String else {
            return try errorResponse(id: id, code: -32600, message: "Invalid Request")
        }

        switch method {
        case "initialize":
            return try successResponse(id: id, result: initializeResult())
        case "tools/list":
            return try successResponse(id: id, result: toolsListResult())
        case "tools/call":
            return try successResponse(id: id, result: await toolCallResult(from: request["params"] as? [String: Any]))
        case "resources/list":
            return try successResponse(id: id, result: ["resources": []])
        case "resources/templates/list":
            return try successResponse(id: id, result: ["resourceTemplates": []])
        case "prompts/list":
            return try successResponse(id: id, result: ["prompts": []])
        default:
            return try errorResponse(id: id, code: -32601, message: "Method not found")
        }
    }

    private func initializeResult() -> [String: Any] {
        [
            "protocolVersion": MCPProtocolVersion.current,
            "capabilities": [
                "tools": ["listChanged": false],
                "resources": ["subscribe": false, "listChanged": false],
                "prompts": ["listChanged": false]
            ],
            "serverInfo": [
                "name": "ETOS Built-in Personal Data",
                "version": "0.1.0"
            ]
        ]
    }

    private func toolsListResult() -> [String: Any] {
        [
            "tools": MCPBuiltInPersonalDataServer.toolDescriptions().map { tool in
                [
                    "name": tool.toolId,
                    "description": tool.description ?? "",
                    "inputSchema": tool.inputSchema?.toAny() ?? [
                        "type": "object",
                        "additionalProperties": false
                    ]
                ] as [String: Any]
            }
        ]
    }

    private func toolCallResult(from params: [String: Any]?) async -> [String: Any] {
        guard let params,
              let name = params["name"] as? String else {
            return errorToolResult(message: "Missing tool name")
        }
        guard MCPBuiltInPersonalDataServer.toolIDs.contains(name) else {
            return errorToolResult(message: "Unknown built-in personal data tool: \(name)")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            let structuredContent: [String: Any]
            if name.hasPrefix("health.") {
                structuredContent = try await healthExecutor.execute(toolName: name, arguments: arguments)
            } else {
                structuredContent = try await eventExecutor.execute(toolName: name, arguments: arguments)
            }
            return successToolResult(structuredContent)
        } catch {
            return errorToolResult(message: error.localizedDescription, toolName: name)
        }
    }

    private func successToolResult(_ structuredContent: [String: Any]) -> [String: Any] {
        let text = (try? Self.prettyPrintedJSON(structuredContent)) ?? "\(structuredContent)"
        return [
            "content": [
                [
                    "type": "text",
                    "text": text
                ]
            ],
            "structuredContent": structuredContent,
            "isError": false
        ]
    }

    private func errorToolResult(message: String, toolName: String? = nil) -> [String: Any] {
        var content: [String: Any] = [
            "error": message,
            "provider": "etos_builtin_personal_data"
        ]
        if let toolName {
            content["tool_name"] = toolName
        }
        let text = (try? Self.prettyPrintedJSON(content)) ?? "\(content)"
        return [
            "content": [
                [
                    "type": "text",
                    "text": text
                ]
            ],
            "structuredContent": content,
            "isError": true
        ]
    }

    private func requestObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPClientError.invalidResponse
        }
        return object
    }

    private func successResponse(id: Any, result: [String: Any]) throws -> Data {
        try responseData([
            "jsonrpc": jsonrpcVersion,
            "id": id,
            "result": result
        ])
    }

    private func errorResponse(id: Any, code: Int, message: String) throws -> Data {
        try responseData([
            "jsonrpc": jsonrpcVersion,
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ])
    }

    private func responseData(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MCPClientError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func prettyPrintedJSON(_ object: [String: Any], prettyPrinted: Bool = true) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MCPClientError.invalidResponse
        }
        let options: JSONSerialization.WritingOptions = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPClientError.invalidResponse
        }
        return text
    }
}

enum MCPBuiltInPersonalDataError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String)
    case unsupportedTool(String)
    case unsupportedPlatform(String)
    case permissionDenied(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return String(format: NSLocalizedString("缺少参数：%@", comment: "Missing MCP tool argument"), name)
        case .invalidArgument(let message), .unsupportedPlatform(let message), .permissionDenied(let message), .unavailable(let message):
            return message
        case .unsupportedTool(let tool):
            return String(format: NSLocalizedString("不支持的个人数据工具：%@", comment: "Unsupported personal data tool"), tool)
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func personalDataString(_ key: String) -> String? {
        (self[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func personalDataRequiredString(_ key: String) throws -> String {
        guard let value = personalDataString(key), !value.isEmpty else {
            throw MCPBuiltInPersonalDataError.missingArgument(key)
        }
        return value
    }

    func personalDataDouble(_ key: String) -> Double? {
        if let number = self[key] as? NSNumber {
            return number.doubleValue
        }
        if let string = personalDataString(key) {
            return Double(string)
        }
        return nil
    }

    func personalDataRequiredDouble(_ key: String) throws -> Double {
        guard let value = personalDataDouble(key) else {
            throw MCPBuiltInPersonalDataError.missingArgument(key)
        }
        return value
    }

    func personalDataInt(_ key: String) -> Int? {
        if let number = self[key] as? NSNumber {
            return number.intValue
        }
        if let string = personalDataString(key) {
            return Int(string)
        }
        return nil
    }

    func personalDataBool(_ key: String) -> Bool? {
        if let bool = self[key] as? Bool {
            return bool
        }
        if let number = self[key] as? NSNumber {
            return number.boolValue
        }
        if let string = personalDataString(key)?.lowercased() {
            if ["true", "yes", "1"].contains(string) { return true }
            if ["false", "no", "0"].contains(string) { return false }
        }
        return nil
    }

    func personalDataDate(_ key: String) throws -> Date? {
        guard let value = personalDataString(key), !value.isEmpty else { return nil }
        guard let date = MCPBuiltInPersonalDataDateCodec.parse(value) else {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                String(format: NSLocalizedString("%@ 必须是 ISO-8601 时间。", comment: "Invalid ISO date argument"), key)
            )
        }
        return date
    }

    func personalDataRequiredDate(_ key: String) throws -> Date {
        guard let date = try personalDataDate(key) else {
            throw MCPBuiltInPersonalDataError.missingArgument(key)
        }
        return date
    }
}

enum MCPBuiltInPersonalDataDateCodec {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standardFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        fractionalFormatter.date(from: text) ?? standardFormatter.date(from: text)
    }

    static func string(_ date: Date?) -> String? {
        guard let date else { return nil }
        return standardFormatter.string(from: date)
    }
}
