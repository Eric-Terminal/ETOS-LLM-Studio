// ============================================================================
// AppToolManagerExecutionTests.swift
// ============================================================================
// AppToolManagerTests 的执行与底层辅助测试。
// ============================================================================

import Testing
import Foundation
import SQLite3
@testable import Shared

@Suite("拓展工具执行测试")
struct AppToolManagerExecutionTests {

    @MainActor
    @Test("填充输入框工具会广播输入框填充请求")
    func testExecuteFillUserInputToolPostsNotification() async throws {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.fillUserInput]
        )

        var latestRequest: AppToolInputDraftRequest?
        let observer = NotificationCenter.default.addObserver(
            forName: .appToolFillUserInputRequested,
            object: nil,
            queue: nil
        ) { notification in
            latestRequest = AppToolInputDraftRequest.decode(from: notification.userInfo)
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        _ = try await manager.executeToolFromChat(
            toolName: AppToolKind.fillUserInput.toolName,
            argumentsJSON: #"{"text":"帮我润色这句话","mode":"append"}"#
        )

        #expect(latestRequest?.text == "帮我润色这句话")
        #expect(latestRequest?.mode == .append)
    }

    @MainActor
    @Test("SQLite 表结构工具可列出目标表")
    func testExecuteListSQLiteTablesToolReturnsCreatedTable() async throws {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.listSQLiteTables]
        )

        let tableName = "tool_test_tables_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let chatDatabaseURL = Persistence.getChatsDirectory().appendingPathComponent("chat-store.sqlite", isDirectory: false)
        try Self.prepareSQLiteFixture(at: chatDatabaseURL, tableName: tableName, rows: [(1, "初始化标题")])
        defer {
            try? Self.dropSQLiteFixture(at: chatDatabaseURL, tableName: tableName)
        }

        let result = try await manager.executeToolFromChat(
            toolName: AppToolKind.listSQLiteTables.toolName,
            argumentsJSON: #"{"database":"chat","include_internal":false}"#
        )

        let payload = try Self.parseJSONObject(result)
        let tables = payload["tables"] as? [[String: Any]] ?? []
        let tableNames = Set(tables.compactMap { $0["name"] as? String })
        #expect(tableNames.contains(tableName))
    }

    @MainActor
    @Test("SQLite 查询与写入工具支持增删改查流程")
    func testExecuteQueryAndMutateSQLiteTools() async throws {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.querySQLite, .mutateSQLite]
        )

        let tableName = "tool_test_crud_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let chatDatabaseURL = Persistence.getChatsDirectory().appendingPathComponent("chat-store.sqlite", isDirectory: false)
        try Self.prepareSQLiteFixture(at: chatDatabaseURL, tableName: tableName, rows: [(1, "初始标题")])
        defer {
            try? Self.dropSQLiteFixture(at: chatDatabaseURL, tableName: tableName)
        }

        let insertArguments = try Self.makeJSONString([
            "database": "chat",
            "sql": "INSERT INTO \"\(tableName)\" (id, title) VALUES (?, ?)",
            "parameters": [2, "新增标题"]
        ])
        let insertResult = try await manager.executeToolFromChat(
            toolName: AppToolKind.mutateSQLite.toolName,
            argumentsJSON: insertArguments
        )
        let insertPayload = try Self.parseJSONObject(insertResult)
        #expect((insertPayload["affectedRows"] as? NSNumber)?.intValue == 1)

        let queryArguments = try Self.makeJSONString([
            "database": "chat",
            "sql": "SELECT id, title FROM \"\(tableName)\" ORDER BY id ASC",
            "max_rows": 10
        ])
        let queryResult = try await manager.executeToolFromChat(
            toolName: AppToolKind.querySQLite.toolName,
            argumentsJSON: queryArguments
        )
        let queryPayload = try Self.parseJSONObject(queryResult)
        let queryRows = queryPayload["rows"] as? [[String: Any]] ?? []
        #expect(queryRows.count == 2)
        #expect(queryRows.last?["title"] as? String == "新增标题")

        let updateArguments = try Self.makeJSONString([
            "database": "chat",
            "sql": "UPDATE \"\(tableName)\" SET title = ? WHERE id = ?",
            "parameters": ["已更新标题", 2]
        ])
        let updateResult = try await manager.executeToolFromChat(
            toolName: AppToolKind.mutateSQLite.toolName,
            argumentsJSON: updateArguments
        )
        let updatePayload = try Self.parseJSONObject(updateResult)
        #expect((updatePayload["affectedRows"] as? NSNumber)?.intValue == 1)

        let verifyArguments = try Self.makeJSONString([
            "database": "chat",
            "sql": "SELECT title FROM \"\(tableName)\" WHERE id = ?",
            "parameters": [2]
        ])
        let verifyResult = try await manager.executeToolFromChat(
            toolName: AppToolKind.querySQLite.toolName,
            argumentsJSON: verifyArguments
        )
        let verifyPayload = try Self.parseJSONObject(verifyResult)
        let verifyRows = verifyPayload["rows"] as? [[String: Any]] ?? []
        #expect(verifyRows.first?["title"] as? String == "已更新标题")

        let deleteArguments = try Self.makeJSONString([
            "database": "chat",
            "sql": "DELETE FROM \"\(tableName)\" WHERE id = ?",
            "parameters": [2]
        ])
        let deleteResult = try await manager.executeToolFromChat(
            toolName: AppToolKind.mutateSQLite.toolName,
            argumentsJSON: deleteArguments
        )
        let deletePayload = try Self.parseJSONObject(deleteResult)
        #expect((deletePayload["affectedRows"] as? NSNumber)?.intValue == 1)
    }

    @MainActor
    @Test("SQLite 工具导出给 Gemini 时数组参数 schema 会包含 items")
    func testSQLiteToolSchemaIncludesItemsForGemini() throws {
        let manager = AppToolManager.shared
        let originalGlobalSwitch = manager.chatToolsEnabled
        let originalEnabledKinds = manager.enabledToolKinds
        let originalApprovalPolicies = manager.configuredApprovalPoliciesByKind
        defer {
            manager.restoreStateForTests(
                chatToolsEnabled: originalGlobalSwitch,
                enabledKinds: originalEnabledKinds,
                approvalPolicies: originalApprovalPolicies
            )
        }

        manager.restoreStateForTests(
            chatToolsEnabled: true,
            enabledKinds: [.querySQLite, .mutateSQLite]
        )

        let adapter = GeminiAdapter()
        let model = RunnableModel(
            provider: Provider(
                id: UUID(),
                name: "Gemini Test Provider",
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                apiKeys: ["test-key"],
                apiFormat: "gemini"
            ),
            model: Model(modelName: "gemini-2.5-pro")
        )
        let messages = [ChatMessage(role: .user, content: "测试一下")]

        guard let request = adapter.buildChatRequest(
            for: model,
            commonPayload: [:],
            messages: messages,
            tools: manager.chatToolsForLLM(),
            audioAttachments: [:],
            imageAttachments: [:],
            fileAttachments: [:]
        ),
        let httpBody = request.httpBody,
        let jsonPayload = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
        let toolsPayload = jsonPayload["tools"] as? [[String: Any]],
        let firstToolGroup = toolsPayload.first,
        let declarations = firstToolGroup["function_declarations"] as? [[String: Any]] else {
            Issue.record("Gemini 请求体中未找到 SQLite 工具声明。")
            return
        }

        let parametersSchemasByToolName = declarations.reduce(into: [String: [String: Any]]()) { result, declaration in
            guard let name = declaration["name"] as? String,
                  let parameters = declaration["parameters"] as? [String: Any],
                  let properties = parameters["properties"] as? [String: Any],
                  let parameterSchema = properties["parameters"] as? [String: Any] else { return }
            result[name] = parameterSchema
        }

        guard let queryParameterSchema = parametersSchemasByToolName[AppToolKind.querySQLite.toolName],
              let mutateParameterSchema = parametersSchemasByToolName[AppToolKind.mutateSQLite.toolName] else {
            Issue.record("Gemini 请求体中未找到 SQLite tools.parameters schema。")
            return
        }

        #expect(queryParameterSchema["type"] as? String == "array")
        #expect(queryParameterSchema["items"] as? [String: Any] != nil)
        #expect(mutateParameterSchema["type"] as? String == "array")
        #expect(mutateParameterSchema["items"] as? [String: Any] != nil)
    }

    @MainActor
    @Test("当前会话文件路径命中时应触发会话刷新判断")
    func testShouldRefreshCurrentSessionMessagesWhenCurrentSessionFileMutated() {
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let shouldRefresh = AppToolManager.shouldRefreshCurrentSessionMessages(
            afterMutatingPaths: [
                "Documents/ChatSessions/sessions/\(sessionID.uuidString.lowercased()).json",
                "Documents/Other/file.txt"
            ],
            currentSessionID: sessionID
        )
        #expect(shouldRefresh)
    }

    @MainActor
    @Test("旧版会话文件路径命中时也应触发会话刷新判断")
    func testShouldRefreshCurrentSessionMessagesWhenLegacySessionFileMutated() {
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let shouldRefresh = AppToolManager.shouldRefreshCurrentSessionMessages(
            afterMutatingPaths: [
                "ChatSessions/\(sessionID.uuidString).json"
            ],
            currentSessionID: sessionID
        )
        #expect(shouldRefresh)
    }

    @MainActor
    @Test("非当前会话文件变更不应触发会话刷新判断")
    func testShouldNotRefreshCurrentSessionMessagesForUnrelatedMutation() {
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let shouldRefresh = AppToolManager.shouldRefreshCurrentSessionMessages(
            afterMutatingPaths: [
                "Documents/ChatSessions/sessions/FFFFFFFF-1111-2222-3333-444444444444.json",
                "Documents/Memory/index.json"
            ],
            currentSessionID: sessionID
        )
        #expect(!shouldRefresh)
    }

    @Test("沙盒工具操作会切到后台线程执行")
    func testSandboxOperationRunsOffMainThread() async throws {
        let isMainThread = try await AppToolManager.runSandboxFileOperationOffMainThread {
            Thread.isMainThread
        }
        #expect(!isMainThread)
    }

    private static func makeJSONString(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "AppToolManagerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "JSON 编码失败"])
        }
        return string
    }

    private static func parseJSONObject(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "AppToolManagerTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "结果不是 UTF-8 文本"])
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AppToolManagerTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "结果不是 JSON 对象"])
        }
        return payload
    }

    private static func prepareSQLiteFixture(
        at databaseURL: URL,
        tableName: String,
        rows: [(id: Int, title: String)]
    ) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var connection: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let connection else {
            let message = connection.flatMap { sqliteMessage(from: $0) } ?? "打开数据库失败"
            throw NSError(domain: "AppToolManagerTests", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_close(connection) }

        let escapedTableName = tableName.replacingOccurrences(of: "\"", with: "\"\"")
        try executeSQLite(
            "DROP TABLE IF EXISTS \"\(escapedTableName)\"",
            on: connection
        )
        try executeSQLite(
            "CREATE TABLE \"\(escapedTableName)\" (id INTEGER PRIMARY KEY, title TEXT NOT NULL)",
            on: connection
        )
        for row in rows {
            let escapedTitle = row.title.replacingOccurrences(of: "'", with: "''")
            try executeSQLite(
                "INSERT INTO \"\(escapedTableName)\" (id, title) VALUES (\(row.id), '\(escapedTitle)')",
                on: connection
            )
        }
    }

    private static func dropSQLiteFixture(at databaseURL: URL, tableName: String) throws {
        var connection: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let connection else {
            let message = connection.flatMap { sqliteMessage(from: $0) } ?? "打开数据库失败"
            throw NSError(domain: "AppToolManagerTests", code: 5, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_close(connection) }

        let escapedTableName = tableName.replacingOccurrences(of: "\"", with: "\"\"")
        try executeSQLite(
            "DROP TABLE IF EXISTS \"\(escapedTableName)\"",
            on: connection
        )
    }

    private static func executeSQLite(_ sql: String, on connection: OpaquePointer) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "AppToolManagerTests",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey: sqliteMessage(from: connection) ?? "执行 SQL 失败"
                ]
            )
        }
    }

    private static func sqliteMessage(from connection: OpaquePointer) -> String? {
        guard let message = sqlite3_errmsg(connection) else { return nil }
        return String(cString: message)
    }
}
