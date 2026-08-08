// ============================================================================
// LocalAgentRuntimeTests.swift
// ============================================================================
// 本地 Agent Runtime 纯逻辑与文件管线测试
// - 环境变量脱敏与双输出边界
// - 命令安全规则、存储布局与损坏检测
// - Linux / Browser 工具协议和 MCP JSON 转换
// ============================================================================

import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("本地 Agent Runtime 测试")
struct LocalAgentRuntimeTests {

    @Test("Browser Agent 不依赖本地 Linux 开关")
    func browserAgentCapabilityIsIndependentFromLinux() {
        let withoutLinux = AgentToolCapabilityPolicy.resolve(
            mode: .agent,
            isWorldbookContextIsolated: false,
            localLinuxEnabled: false
        )
        #expect(withoutLinux.preparesAgentRun)
        #expect(withoutLinux.includesConversationTools)
        #expect(withoutLinux.includesBrowserTools)
        #expect(!withoutLinux.includesLocalLinuxTools)

        let chat = AgentToolCapabilityPolicy.resolve(
            mode: .chat,
            isWorldbookContextIsolated: false,
            localLinuxEnabled: true
        )
        #expect(!chat.preparesAgentRun)
        #expect(!chat.includesBrowserTools)
        #expect(!chat.includesLocalLinuxTools)

        let isolated = AgentToolCapabilityPolicy.resolve(
            mode: .agent,
            isWorldbookContextIsolated: true,
            localLinuxEnabled: true
        )
        #expect(!isolated.preparesAgentRun)
        #expect(!isolated.includesBrowserTools)
        #expect(!isolated.includesLocalLinuxTools)
    }

    @Test("Browser 能力完整时不显示能力检查区域")
    func completeBrowserCapabilitiesHaveNoMissingItems() {
        let complete = BrowserAgentCapabilities(
            platform: "watchOS",
            isExperimental: true,
            supportsNavigation: true,
            supportsSnapshot: true,
            supportsClick: true,
            supportsTyping: true,
            supportsScrolling: true,
            supportsJavaScript: true,
            supportsScreenshot: true,
            supportsDownload: true,
            supportsUserTakeover: true,
            supportsIPhoneDelegation: true,
            notes: []
        )
        #expect(complete.unavailableCapabilities.isEmpty)

        let limited = BrowserAgentCapabilities(
            platform: "watchOS",
            isExperimental: true,
            supportsNavigation: true,
            supportsSnapshot: true,
            supportsClick: true,
            supportsTyping: true,
            supportsScrolling: true,
            supportsJavaScript: true,
            supportsScreenshot: false,
            supportsDownload: false,
            supportsUserTakeover: true,
            supportsIPhoneDelegation: true,
            notes: []
        )
        #expect(limited.unavailableCapabilities == [.screenshot, .download])
    }

    @Test("环境变量脱敏遵循长度、重叠和关闭规则")
    func redactEnvironmentValues() {
        let enabled = LocalLinuxProcessEnvironmentProvider.redactModelOutput(
            "short abc token-123456 token-123456-extra",
            values: ["abc", "token-123456", "token-123456-extra"],
            isEnabled: true
        )
        #expect(enabled.didRedact)
        #expect(!enabled.text.contains("token-123456"))
        #expect(enabled.text.contains("abc"))

        let disabled = LocalLinuxProcessEnvironmentProvider.redactModelOutput(
            "token-123456",
            values: ["token-123456"],
            isEnabled: false
        )
        #expect(disabled.text == "token-123456")
        #expect(!disabled.didRedact)
    }

    @Test("输出收集器跨 chunk 打码且保留用户原始输出")
    func outputCollectorRedactsAcrossChunks() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("raw.log")
        let modelURL = directory.appendingPathComponent("model.log")
        let collector = try LocalLinuxOutputCollector(
            rawURL: rawURL,
            modelURL: modelURL,
            redactionValues: ["super-secret"],
            privacyEnabled: true,
            modelByteLimit: 4_096
        )

        collector.append(stream: .stdout, data: Data("value=super-".utf8))
        collector.append(stream: .stdout, data: Data("secret\n".utf8), streamEnded: true)
        collector.finish()

        let modelOutput = try String(contentsOf: modelURL, encoding: .utf8)
        let snapshot = collector.snapshot()
        #expect(collector.userVisiblePreview().contains("super-secret"))
        #expect(!modelOutput.contains("super-secret"))
        #expect(modelOutput.contains("su********et"))
        #expect(modelOutput.contains(NSLocalizedString(
            "\n[隐私模式已按环境变量值打码；用户原始日志未被修改]\n",
            comment: "Linux model output redaction notice"
        )))
        #expect(snapshot.didRedact)
        #expect(snapshot.stdoutBytes == UInt64("value=super-secret\n".utf8.count))
    }

    @Test("模型输出达到预算后标记截断但原始输出继续写入")
    func outputCollectorTruncatesOnlyModelProjection() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("raw.log")
        let modelURL = directory.appendingPathComponent("model.log")
        let collector = try LocalLinuxOutputCollector(
            rawURL: rawURL,
            modelURL: modelURL,
            redactionValues: [],
            privacyEnabled: true,
            modelByteLimit: 16
        )
        let content = String(repeating: "x", count: 128)
        collector.append(stream: .stderr, data: Data(content.utf8), streamEnded: true)
        collector.finish()

        let snapshot = collector.snapshot()
        let modelOutput = try String(contentsOf: modelURL, encoding: .utf8)
        #expect(snapshot.didTruncateModelOutput)
        #expect(snapshot.stderrBytes == 128)
        #expect(collector.userVisiblePreview().contains(content))
        #expect(modelOutput.contains("模型输出已截断"))
    }

    @Test("原始输出分页跨越大帧时不会丢失内容")
    func rawOutputPagingPreservesFrameRemainder() async throws {
        let documents = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let manager = LocalLinuxStorageManager(documentsDirectory: documents)
        let layout = try await manager.prepareLayout()
        let directory = layout.workspaces.appendingPathComponent("paging", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rawURL = directory.appendingPathComponent("raw.log")
        let modelURL = directory.appendingPathComponent("model.log")
        let collector = try LocalLinuxOutputCollector(
            rawURL: rawURL,
            modelURL: modelURL,
            redactionValues: [],
            privacyEnabled: false,
            modelByteLimit: 1_024
        )
        let expected = String(repeating: "0123456789", count: 10)
        collector.append(stream: .stdout, data: Data(expected.utf8), streamEnded: true)
        collector.finish()

        let relativePath = try await manager.relativePath(for: rawURL)
        var cursor = LocalLinuxRawOutputCursor()
        var joined = ""
        var visited: Set<LocalLinuxRawOutputCursor> = []
        while true {
            #expect(visited.insert(cursor).inserted)
            let page = try await manager.readRawOutputPage(
                relativePath: relativePath,
                cursor: cursor,
                maximumBytes: 1
            )
            joined += page.text
            guard let next = page.nextCursor else {
                #expect(page.isComplete)
                break
            }
            cursor = next
        }
        #expect(joined == "\n[stdout]\n" + expected)
    }

    @Test("命令规则按作用域匹配前缀与正则并可整体关闭")
    func commandSafetyRules() {
        let prefix = LocalLinuxCommandRule(
            name: "删除提醒",
            pattern: "/bin/rm -rf",
            matchKind: .prefix,
            scope: .run,
            action: .confirm,
            sortIndex: 0
        )
        let expression = LocalLinuxCommandRule(
            name: "包安装",
            pattern: #"(^|[;&|]\s*)apk\s+add\b"#,
            matchKind: .regularExpression,
            scope: .shell,
            action: .warn,
            sortIndex: 1
        )
        let runRequest = LocalLinuxJobRequest(
            executable: "/bin/rm",
            arguments: ["/bin/rm", "-rf", "/tmp/demo"]
        )
        let shellRequest = LocalLinuxJobRequest(
            executable: "/bin/sh",
            arguments: ["/bin/sh", "-lc", "apk add bash"],
            shellScript: "echo ready; apk add bash"
        )

        let runMatch = LocalLinuxApprovalPolicy.evaluate(
            rules: [prefix, expression],
            request: runRequest,
            kind: .run,
            isEnabled: true
        )
        let shellMatch = LocalLinuxApprovalPolicy.evaluate(
            rules: [prefix, expression],
            request: shellRequest,
            kind: .shell,
            isEnabled: true
        )
        let disabled = LocalLinuxApprovalPolicy.evaluate(
            rules: [prefix],
            request: runRequest,
            kind: .run,
            isEnabled: false
        )

        #expect(runMatch?.ruleID == prefix.id)
        #expect(shellMatch?.ruleID == expression.id)
        #expect(disabled == nil)
    }

    @Test("命令超时支持关闭和桥接可表示的长任务")
    func commandTimeoutConversion() throws {
        #expect(try iSHAppleBridgeCommandSession.timeoutMilliseconds(nil) == 0)
        #expect(try iSHAppleBridgeCommandSession.timeoutMilliseconds(0) == UInt32.max)
        #expect(try iSHAppleBridgeCommandSession.timeoutMilliseconds(7_200) == 7_200_000)
        #expect(throws: LocalLinuxRuntimeError.self) {
            try iSHAppleBridgeCommandSession.timeoutMilliseconds(Double(UInt32.max) / 1_000)
        }
    }

    @Test("结构化命令按冻结 PATH 解析可执行文件候选")
    func commandExecutableSearchCandidates() {
        #expect(
            LocalLinuxJobScheduler.executableSearchCandidates(
                command: "python3",
                environment: ["PATH": "/usr/local/bin:/usr/bin:tools:"],
                workingDirectory: "/workspace/demo"
            ) == [
                "/usr/local/bin/python3",
                "/usr/bin/python3",
                "/workspace/demo/tools/python3",
                "/workspace/demo/python3"
            ]
        )
        #expect(
            LocalLinuxJobScheduler.executableSearchCandidates(
                command: "./configure",
                environment: ["PATH": "/bin"],
                workingDirectory: "/workspace/demo"
            ) == ["./configure"]
        )
    }

    @Test("Linux 存储布局稳定且收据损坏会被识别")
    func storageLayoutAndIntegrity() async throws {
        let documents = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let manager = LocalLinuxStorageManager(documentsDirectory: documents)
        let layout = manager.layout

        #expect(layout.root == documents.appendingPathComponent("Linux", isDirectory: true))
        #expect(layout.rootFSData.path.hasSuffix("Linux/System/RootFS/data"))
        #expect(layout.home.path.hasSuffix("Linux/Home"))
        #expect(layout.shared.path.hasSuffix("Linux/Shared"))
        #expect(layout.workspaces.path.hasSuffix("Linux/Workspaces"))
        let startupMounts = try await LocalLinuxMountManager(storage: manager).prepareStartupMounts().mounts
        #expect(startupMounts.contains { $0.id == LocalLinuxMountManager.homeMountID })
        #expect(startupMounts.contains { $0.id == LocalLinuxMountManager.workspaceMountID })
        #expect(!startupMounts.contains { $0.guestDirectory == LocalLinuxMountManager.sharedMountGuestPath })
        let integrity = await manager.systemIntegrity()
        #expect(integrity == .notInstalled)

        try FileManager.default.createDirectory(at: layout.rootFSData, withIntermediateDirectories: true)
        try Data().write(to: layout.rootFS.appendingPathComponent("meta.db"))
        try "invalid".write(
            to: layout.rootFS.appendingPathComponent("rootfs-installation.txt"),
            atomically: true,
            encoding: .utf8
        )
        guard case .damaged = await manager.systemIntegrity() else {
            Issue.record("无效 RootFS 收据没有被标记为损坏")
            return
        }
    }

    @Test("内置环境 recipe 不会隐式包含执行器且可按命令匹配")
    func environmentRecipes() throws {
        #expect(LocalLinuxEnvironmentRecipes.matching(command: "/usr/bin/python3")?.id == "python")
        #expect(LocalLinuxEnvironmentRecipes.matching(command: "uvx")?.id == "uvx")
        #expect(LocalLinuxEnvironmentRecipes.matching(command: "unknown-tool") == nil)
        #expect(LocalLinuxEnvironmentRecipes.all.allSatisfy { $0.command.hasPrefix("apk add ") })
    }

    @Test("Linux、Browser 与反馈工具协议暴露完整动作")
    func toolDefinitionsExposeExpectedContract() throws {
        #expect(Set(LocalLinuxToolDefinitions.all.map(\.name)) == ["linux_run", "linux_shell", "linux_process"])
        #expect(BrowserAgentToolDefinitions.all.map(\.name) == ["browser_control"])

        let browserData = try JSONEncoder().encode(BrowserAgentToolDefinitions.all[0].parameters)
        let browserSchema = try #require(String(data: browserData, encoding: .utf8))
        #expect(browserSchema.contains("evaluate_javascript"))
        #expect(browserSchema.contains("screenshot"))
        #expect(browserSchema.contains("download"))

        let feedbackData = try JSONEncoder().encode(AppToolKind.submitFeedbackTicket.parameters)
        let feedbackSchema = try #require(String(data: feedbackData, encoding: .utf8))
        #expect(feedbackSchema.contains("linux_runtime_diagnostic_id"))
    }

    @Test("MCP JSON 导入 stdio 并在无敏感导出时移除凭据")
    func mcpConfigurationTransfer() throws {
        let imported = try MCPServerConfigurationTransferService.importConfigurations(
            from: Data(#"{"mcpServers":{"git":{"type":"stdio","command":"uvx","args":["mcp-server-git"],"env":{"TOKEN":"secret"}}}}"#.utf8)
        )
        let server = try #require(imported.servers.first)
        #expect(imported.sensitiveServerNames == ["git"])
        if case .localStdio(let configuration) = server.transport {
            #expect(configuration.command == "uvx")
            #expect(configuration.arguments == ["mcp-server-git"])
            #expect(configuration.environment["TOKEN"] == "secret")
        } else {
            Issue.record("stdio 配置未转换为本地 Linux transport")
        }

        let remote = MCPServerConfiguration(
            displayName: "remote",
            transport: .http(
                endpoint: URL(string: "https://example.com/mcp")!,
                apiKey: "api-secret",
                additionalHeaders: ["Authorization": "Bearer secret", "X-Client": "ETOS"]
            )
        )
        let exported = try MCPServerConfigurationTransferService.exportConfigurations(
            [remote],
            includeSecrets: false
        )
        let exportedText = try #require(String(data: exported, encoding: .utf8))
        #expect(!exportedText.contains("Bearer secret"))
        #expect(!exportedText.contains("api-secret"))
        #expect(exportedText.contains("X-Client"))
    }

    @Test("同步合并会把 stdio 字面环境变量转换为 GRDB 引用")
    func mcpSyncMergeMaterializesEnvironmentReferences() throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let variableName = "ETOS_TEST_\(suffix)"
        let server = MCPServerConfiguration(
            displayName: "stdio-\(suffix)",
            transport: .localStdio(
                configuration: MCPLocalStdioConfiguration(
                    command: "env",
                    environment: [variableName: "secret-\(suffix)"]
                )
            )
        )

        let result = SyncEngine.mergeMCPServers([server])
        let stored = try #require(MCPServerStore.loadServers().first(where: { $0.id == server.id }))
        defer {
            MCPServerStore.delete(stored)
            for variable in Persistence.loadLocalLinuxEnvironmentVariables()
            where variable.name == variableName {
                _ = Persistence.deleteLocalLinuxEnvironmentVariable(id: variable.id)
            }
        }

        #expect(result.imported == 1)
        if case .localStdio(let configuration) = stored.transport {
            #expect(configuration.environment.isEmpty)
            #expect(configuration.environmentVariableIDs.count == 1)
            let referenced = Persistence.loadLocalLinuxEnvironmentVariables().filter {
                configuration.environmentVariableIDs.contains($0.id)
            }
            #expect(referenced.count == 1)
            #expect(referenced.first?.name == variableName)
            #expect(referenced.first?.value == "secret-\(suffix)")
        } else {
            Issue.record("同步合并后的 MCP 不是本地 stdio transport")
        }
    }

    @Test("Browser 数据 profile 与快照可以稳定编码")
    func browserModelsCodableRoundTrip() throws {
        let snapshot = BrowserAgentSnapshot(
            title: "Example",
            url: "https://example.com",
            text: "正文",
            elements: [.init(index: 0, role: "button", label: "继续", value: nil)],
            wasTruncated: false
        )
        let decoded = try JSONDecoder().decode(
            BrowserAgentSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded == snapshot)
        #expect(BrowserAgentDataProfile(rawValue: "session_isolated") == .sessionIsolated)
        #expect(BrowserAgentDataProfile(rawValue: "persistent_shared") == .persistentShared)
    }

    #if canImport(WebKit) && canImport(UIKit) && !os(watchOS)
    @Test("Browser 下载只携带目标域和路径适用的 Cookie")
    func browserDownloadCookieScope() throws {
        let cookie = try #require(HTTPCookie(properties: [
            .domain: ".example.com",
            .path: "/account",
            .name: "session",
            .value: "secret",
            .secure: "TRUE"
        ]))
        #expect(BrowserSessionManager.cookieApplies(cookie, to: URL(string: "https://api.example.com/account/file")!))
        #expect(!BrowserSessionManager.cookieApplies(cookie, to: URL(string: "https://api.example.com/accounting")!))
        #expect(!BrowserSessionManager.cookieApplies(cookie, to: URL(string: "http://api.example.com/account/file")!))
        #expect(!BrowserSessionManager.cookieApplies(cookie, to: URL(string: "https://example.net/account/file")!))
    }
    #endif

    @Test("任务规则命中与 Agent 提示词会随 Run 快照稳定编码")
    func agentRunSnapshotCodableRoundTrip() throws {
        let ruleID = UUID()
        let request = LocalLinuxJobRequest(
            executable: "/bin/rm",
            arguments: ["/bin/rm", "-rf", "/tmp/demo"],
            commandRuleMatch: LocalLinuxCommandRuleMatch(
                ruleID: ruleID,
                ruleName: "删除确认",
                action: .confirm,
                matchedText: "/bin/rm -rf /tmp/demo"
            )
        )
        let decodedRequest = try JSONDecoder().decode(
            LocalLinuxJobRequest.self,
            from: JSONEncoder().encode(request)
        )
        #expect(decodedRequest.commandRuleMatch?.ruleID == ruleID)
        #expect(decodedRequest.commandRuleMatch?.matchedText == "/bin/rm -rf /tmp/demo")

        let sessionID = UUID()
        let runID = UUID()
        let workspaceID = UUID()
        let promptID = UUID()
        let context = AgentRuntimeContext(
            sessionID: sessionID,
            runID: runID,
            rootRunID: runID,
            parentRunID: nil,
            triggeringMessageID: UUID(),
            toolCallID: nil,
            workspaceID: workspaceID,
            workingDirectory: "/workspace/demo",
            environmentSnapshotHash: "snapshot-hash",
            environmentValues: ["TOKEN": "secret"],
            environmentRedactionValues: ["secret"],
            environmentReferenceSnapshots: [],
            mountIDs: [],
            selectedMCPServerIDs: [],
            selectedMCPServerConfigurations: [],
            browserSessionID: sessionID,
            browserDataProfile: .sessionIsolated,
            promptProfileID: promptID,
            promptContent: "固定的 Agent 提示词",
            executorDeviceID: "test-device",
            mode: .agent
        )
        let decodedContext = try JSONDecoder().decode(
            AgentRuntimeContext.self,
            from: JSONEncoder().encode(context)
        )
        #expect(decodedContext == context)
        #expect(decodedContext.promptProfileID == promptID)
        #expect(decodedContext.promptContent == "固定的 Agent 提示词")
    }

    @Test("v13 Linux 任务迁移保留记录并接受 Browser 类型")
    func browserJobSchemaMigration() throws {
        let queue = try DatabaseQueue()
        let existingID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL)")
            try PersistenceGRDBStore.createLocalAgentRuntimeTables(db)
            try db.execute(sql: "DROP TABLE local_linux_diagnostics")
            try db.execute(sql: "DROP TABLE local_linux_audit")
            try db.execute(sql: "DROP TABLE local_linux_jobs")
            try db.execute(sql: """
                CREATE TABLE local_linux_jobs (
                    id TEXT PRIMARY KEY NOT NULL,
                    request_id INTEGER NOT NULL UNIQUE,
                    kind TEXT NOT NULL CHECK(kind IN ('run', 'shell', 'terminal', 'local_mcp', 'recipe')),
                    session_id TEXT, run_id TEXT, root_run_id TEXT, parent_run_id TEXT,
                    tool_call_id TEXT, workspace_id TEXT, executor_device_id TEXT NOT NULL,
                    request_json BLOB NOT NULL,
                    state TEXT NOT NULL CHECK(state IN (
                        'queued', 'starting', 'running', 'waiting_for_input',
                        'completed', 'failed', 'cancelled', 'interrupted'
                    )),
                    completion_reason TEXT, exit_code INTEGER, termination_signal INTEGER,
                    linux_error INTEGER, stdout_bytes INTEGER NOT NULL DEFAULT 0,
                    stderr_bytes INTEGER NOT NULL DEFAULT 0, output_relative_path TEXT,
                    model_output_relative_path TEXT, diagnostic_id TEXT,
                    created_at REAL NOT NULL, started_at REAL, finished_at REAL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE local_linux_diagnostics (
                    id TEXT PRIMARY KEY NOT NULL, job_id TEXT, request_id INTEGER NOT NULL,
                    category TEXT NOT NULL, payload_json BLOB NOT NULL,
                    redacted_summary TEXT NOT NULL, occurrence_count INTEGER NOT NULL DEFAULT 1,
                    created_at REAL NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE local_linux_audit (
                    id TEXT PRIMARY KEY NOT NULL, session_id TEXT, run_id TEXT, job_id TEXT,
                    action TEXT NOT NULL, decision TEXT NOT NULL, scope TEXT NOT NULL,
                    matched_rule_id TEXT, redacted_summary TEXT NOT NULL,
                    executor_device_id TEXT NOT NULL, created_at REAL NOT NULL
                )
            """)
            try db.execute(
                sql: """
                    INSERT INTO local_linux_jobs (
                        id, request_id, kind, executor_device_id, request_json, state, created_at
                    ) VALUES (?, 1, 'run', 'test-device', ?, 'completed', 1)
                """,
                arguments: [existingID, Data("{}".utf8)]
            )

            try PersistenceGRDBStore.migrateLocalAgentBrowserSchema(db)

            let preserved = try String.fetchOne(
                db,
                sql: "SELECT kind FROM local_linux_jobs WHERE id = ?",
                arguments: [existingID]
            )
            #expect(preserved == "run")
            try db.execute(
                sql: """
                    INSERT INTO local_linux_jobs (
                        id, request_id, kind, executor_device_id, request_json, state, created_at
                    ) VALUES (?, 2, 'browser', 'test-device', ?, 'completed', 2)
                """,
                arguments: [UUID().uuidString, Data("{}".utf8)]
            )
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM local_linux_jobs") == 2)
        }
    }

    @Test("本地 stdio MCP 迁移保留服务器与工具并扩展 transport 约束")
    func mcpLocalStdioTransportMigration() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE mcp_servers (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    notes TEXT,
                    is_selected_for_chat INTEGER NOT NULL DEFAULT 0,
                    sort_index INTEGER NOT NULL DEFAULT 0,
                    status TEXT NOT NULL DEFAULT 'idle' CHECK(status IN ('idle', 'ready')),
                    transport_kind TEXT NOT NULL CHECK(transport_kind IN (
                        'http', 'sse', 'oauth',
                        'built_in_search', 'built_in_app_tool', 'built_in_personal_data'
                    )),
                    endpoint_url TEXT,
                    message_endpoint_url TEXT,
                    sse_endpoint_url TEXT,
                    metadata_cached_at REAL,
                    updated_at REAL NOT NULL,
                    api_key TEXT,
                    additional_headers_json TEXT,
                    disabled_tool_ids_json TEXT,
                    tool_approval_policies_json TEXT,
                    oauth_payload_json TEXT,
                    stream_resumption_token TEXT,
                    info_json TEXT,
                    resources_json TEXT,
                    resource_templates_json TEXT,
                    prompts_json TEXT,
                    roots_json TEXT
                )
            """)
            try db.execute(sql: """
                CREATE TABLE mcp_tools (
                    server_id TEXT NOT NULL REFERENCES mcp_servers(id) ON DELETE CASCADE,
                    tool_name TEXT NOT NULL,
                    description TEXT,
                    sort_index INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    input_schema_json TEXT,
                    examples_json TEXT,
                    PRIMARY KEY(server_id, tool_name)
                )
            """)
            let serverID = UUID().uuidString
            try db.execute(
                sql: """
                    INSERT INTO mcp_servers (
                        id, display_name, status, transport_kind, updated_at
                    ) VALUES (?, '现有服务器', 'ready', 'http', 1)
                """,
                arguments: [serverID]
            )
            try db.execute(
                sql: """
                    INSERT INTO mcp_tools (
                        server_id, tool_name, description, updated_at
                    ) VALUES (?, 'existing_tool', '保留的工具', 1)
                """,
                arguments: [serverID]
            )

            try PersistenceAuxiliaryGRDBStore.migrateMCPServerLocalStdioTransport(db)

            let tableSQL = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'mcp_servers'"
            )
            #expect(tableSQL?.contains("'local_stdio'") == true)
            #expect(try String.fetchOne(
                db,
                sql: "SELECT tool_name FROM mcp_tools WHERE server_id = ?",
                arguments: [serverID]
            ) == "existing_tool")
            try db.execute(
                sql: """
                    INSERT INTO mcp_servers (
                        id, display_name, status, transport_kind, updated_at
                    ) VALUES (?, '本地服务器', 'idle', 'local_stdio', 2)
                """,
                arguments: [UUID().uuidString]
            )
            #expect(try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM mcp_servers WHERE transport_kind = 'local_stdio'"
            ) == 1)
        }
    }

    @Test("本地 Agent 修复迁移可以从缺失表的数据库重建")
    func localAgentSchemaRepairFromMissingTables() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL)")
            try PersistenceGRDBStore.migrateLocalAgentBrowserSchema(db)
            let jobTable = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'local_linux_jobs'"
            )
            #expect(jobTable?.contains("'browser'") == true)
        }
    }

    @Test("RootFS 更新只沿清单中的确定链路执行")
    func rootFSMigrationUsesDeclaredPath() throws {
        let seedA = String(repeating: "a", count: 64)
        let seedB = String(repeating: "b", count: 64)
        let seedC = String(repeating: "c", count: 64)
        let scriptSHA = String(repeating: "d", count: 64)
        let migrations = [
            LocalLinuxRootFSMigrationDefinition(
                id: "001-a-to-b",
                fromSeedSHA256: seedA,
                toSeedSHA256: seedB,
                scriptFile: "001-a-to-b.sh",
                scriptSHA256: scriptSHA
            ),
            LocalLinuxRootFSMigrationDefinition(
                id: "002-b-to-c",
                fromSeedSHA256: seedB,
                toSeedSHA256: seedC,
                scriptFile: "002-b-to-c.sh",
                scriptSHA256: scriptSHA
            )
        ]
        let resource = LocalLinuxRootFSMigrationResource(
            manifestURL: URL(fileURLWithPath: "/manifest.json"),
            manifest: LocalLinuxRootFSMigrationManifest(
                format: "etos-rootfs-migrations-v1",
                targetSeedSHA256: seedC,
                migrations: migrations
            ),
            scriptURLs: [:]
        )

        #expect(try resource.migrationPath(from: seedA).map(\.id) == ["001-a-to-b", "002-b-to-c"])
        #expect(try resource.migrationPath(from: seedC).isEmpty)
        #expect(throws: LocalLinuxRuntimeError.self) {
            _ = try resource.migrationPath(from: String(repeating: "e", count: 64))
        }
    }

    @Test("RootFS 迁移完成后只推进安装收据")
    func rootFSMigrationAdvancesReceipt() async throws {
        let documents = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let manager = LocalLinuxStorageManager(documentsDirectory: documents)
        let layout = try await manager.prepareLayout()
        try FileManager.default.createDirectory(at: layout.rootFSData, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: layout.rootFS.appendingPathComponent("meta.db").path,
            contents: Data()
        )
        let previousSeed = String(repeating: "a", count: 64)
        let targetSeed = String(repeating: "b", count: 64)
        try Data("format=ish-rootfs-install-v1\nseed_archive_sha256=\(previousSeed)\n".utf8)
            .write(to: layout.rootFS.appendingPathComponent("rootfs-installation.txt"))

        try await manager.recordInstalledSeedSHA256(targetSeed)

        #expect(await manager.systemIntegrity() == .installed(seedSHA256: targetSeed))
        #expect(FileManager.default.fileExists(atPath: layout.rootFSData.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-agent-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
