// ============================================================================
// SystemEntryAppIntents.swift
// ETOS LLM Studio iOS App
// ============================================================================

import AppIntents
import ETOSCore
import Foundation

struct ETOSSessionEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("会话", table: "Localizable")
    )
    static var defaultQuery = ETOSSessionEntityQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ETOSSessionEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [ETOSSessionEntity] {
        let wanted = Set(identifiers)
        let sessions = await Task.detached(priority: .userInitiated) {
            Persistence.loadChatSessions()
        }.value
        return sessions
            .filter { wanted.contains($0.id) }
            .map { ETOSSessionEntity(id: $0.id, name: String($0.name.prefix(80))) }
    }

    func suggestedEntities() async throws -> [ETOSSessionEntity] {
        let sessions = await Task.detached(priority: .userInitiated) {
            Array(Persistence.loadChatSessions().prefix(20))
        }.value
        return sessions.map {
            ETOSSessionEntity(id: $0.id, name: String($0.name.prefix(80)))
        }
    }

    func entities(matching string: String) async throws -> [ETOSSessionEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessions = await Task.detached(priority: .userInitiated) {
            Persistence.loadChatSessions()
        }.value
        return sessions
            .lazy
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .prefix(20)
            .map { ETOSSessionEntity(id: $0.id, name: String($0.name.prefix(80))) }
    }
}

struct ETOSMemoryEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("记忆", table: "Localizable")
    )
    static var defaultQuery = ETOSMemoryEntityQuery()

    let id: UUID
    let content: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(String(content.prefix(80)))")
    }
}

struct ETOSMemoryEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [ETOSMemoryEntity] {
        let wanted = Set(identifiers)
        let memories = await Task.detached(priority: .userInitiated) {
            await MemoryManager.shared.getAllMemories()
        }.value
        return memories
            .filter { wanted.contains($0.id) }
            .prefix(20)
            .map { ETOSMemoryEntity(id: $0.id, content: $0.content) }
    }

    func suggestedEntities() async throws -> [ETOSMemoryEntity] {
        let memories = await Task.detached(priority: .userInitiated) {
            await MemoryManager.shared.getAllMemories()
        }.value
        return memories
            .filter { !$0.isArchived }
            .prefix(20)
            .map { ETOSMemoryEntity(id: $0.id, content: $0.content) }
    }

    func entities(matching string: String) async throws -> [ETOSMemoryEntity] {
        let items = try await SystemEntryCoordinator.shared.searchMemory(string, limit: 10)
        return items.map { ETOSMemoryEntity(id: $0.id, content: $0.content) }
    }
}

struct StartETOSAgentTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "新建 Agent 任务"
    static var description = IntentDescription("在新会话中交给 ETOS Agent 处理。")

    @Parameter(title: "任务") var prompt: String
    @Parameter(title: "标题") var taskTitle: String?
    @Parameter(title: "请求 ID") var requestID: String?

    init() {
        requestID = UUID().uuidString
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SystemEntryCoordinator.shared.startTask(
            prompt: prompt,
            mode: .agent,
            title: taskTitle,
            requestID: UUID(uuidString: requestID ?? "") ?? UUID()
        )
        let message = result.wasAlreadyHandled
            ? NSLocalizedString("该任务已经接收，将继续使用原会话。", comment: "Idempotent Agent intent result")
            : NSLocalizedString("任务已交给 ETOS Agent。", comment: "Agent intent success")
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct ContinueETOSSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "继续指定会话"
    static var description = IntentDescription("把新消息发送到指定的 ETOS 会话。")

    @Parameter(title: "会话") var session: ETOSSessionEntity
    @Parameter(title: "消息") var prompt: String
    @Parameter(title: "请求 ID") var requestID: String?

    init() {
        requestID = UUID().uuidString
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await SystemEntryCoordinator.shared.continueTask(
            sessionID: session.id,
            prompt: prompt,
            requestID: UUID(uuidString: requestID ?? "") ?? UUID()
        )
        return .result(dialog: IntentDialog(stringLiteral: NSLocalizedString("消息已发送。", comment: "Continue session intent result")))
    }
}

struct GetETOSTaskStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "获取 Agent 状态"
    static var description = IntentDescription("查看指定会话或最近任务的运行状态。")

    @Parameter(title: "会话") var session: ETOSSessionEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let result = try await SystemEntryCoordinator.shared.status(sessionID: session?.id)
        let status = localizedStatus(result.status)
        let message = String(
            format: NSLocalizedString("%@：%@", comment: "Agent status intent result"),
            result.sessionName,
            status
        )
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }

    private func localizedStatus(_ status: ETOSTaskSnapshotStatus) -> String {
        switch status {
        case .queued: return NSLocalizedString("等待中", comment: "Queued task status")
        case .running: return NSLocalizedString("运行中", comment: "Running task status")
        case .waitingForApproval: return NSLocalizedString("等待批准", comment: "Waiting approval task status")
        case .waitingForInput: return NSLocalizedString("等待输入", comment: "Waiting input task status")
        case .completed: return NSLocalizedString("已完成", comment: "Completed task status")
        case .failed: return NSLocalizedString("失败", comment: "Failed task status")
        case .cancelled: return NSLocalizedString("已取消", comment: "Cancelled task status")
        }
    }
}

struct StopETOSTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "停止 Agent 任务"
    static var description = IntentDescription("停止指定会话中正在运行的请求。")

    @Parameter(title: "会话") var session: ETOSSessionEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await SystemEntryCoordinator.shared.stop(sessionID: session.id)
        return .result(dialog: IntentDialog(stringLiteral: NSLocalizedString("已请求停止任务。", comment: "Stop task intent result")))
    }
}

struct SaveETOSMemoryIntent: AppIntent {
    static var title: LocalizedStringResource = "保存到 ETOS 记忆"
    static var description = IntentDescription("把文本写入 ETOS 长期记忆，并保留快捷指令来源记录。")

    @Parameter(title: "内容") var content: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await SystemEntryCoordinator.shared.saveMemory(
            content,
            shortcutName: NSLocalizedString("保存到 ETOS 记忆", comment: "Memory shortcut source")
        )
        return .result(dialog: IntentDialog(stringLiteral: NSLocalizedString("记忆已保存。", comment: "Save memory intent result")))
    }
}

struct SearchETOSMemoryIntent: AppIntent {
    static var title: LocalizedStringResource = "搜索 ETOS 记忆"
    static var description = IntentDescription("在本机长期记忆中搜索相关内容。")

    @Parameter(title: "关键词") var query: String
    @Parameter(title: "数量", default: 5) var limit: Int

    func perform() async throws -> some IntentResult & ReturnsValue<[ETOSMemoryEntity]> & ProvidesDialog {
        let items = try await SystemEntryCoordinator.shared.searchMemory(query, limit: limit)
        let entities = items.map { ETOSMemoryEntity(id: $0.id, content: $0.content) }
        let message = String(
            format: NSLocalizedString("找到 %d 条记忆。", comment: "Memory search result count"),
            entities.count
        )
        return .result(value: entities, dialog: IntentDialog(stringLiteral: message))
    }
}

struct OpenETOSSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "打开 ETOS 会话"
    static var openAppWhenRun = true

    @Parameter(title: "会话") var session: ETOSSessionEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let sessionID = session.id
        guard let value = await Task.detached(priority: .userInitiated, operation: {
            Persistence.loadChatSession(id: sessionID)
        }).value else {
            throw ETOSSystemEntryError.sessionNotFound
        }
        ChatService.shared.setCurrentSession(value)
        NotificationCenter.default.post(name: .requestSwitchToChatTab, object: nil)
        return .result(dialog: IntentDialog(stringLiteral: NSLocalizedString("已打开会话。", comment: "Open session intent result")))
    }
}

struct OpenETOSMemoryIntent: AppIntent {
    static var title: LocalizedStringResource = "打开 ETOS 记忆"
    static var openAppWhenRun = true

    @Parameter(title: "记忆") var memory: ETOSMemoryEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let memoryID = memory.id
        let item = await Task.detached(priority: .userInitiated) {
            await MemoryManager.shared.getAllMemories().first { $0.id == memoryID }
        }.value
        NotificationCenter.default.post(name: .requestSystemEntryRoute, object: SystemEntryRoute.memory(item))
        return .result(dialog: IntentDialog(stringLiteral: NSLocalizedString("已打开记忆。", comment: "Open memory intent result")))
    }
}

struct OpenETOSBrowserIntent: AppIntent {
    static var title: LocalizedStringResource = "打开 Browser Agent"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .requestSystemEntryRoute, object: SystemEntryRoute.browser)
        return .result()
    }
}

struct OpenETOSTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "打开 ETOS 终端"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .requestSystemEntryRoute, object: SystemEntryRoute.terminal)
        return .result()
    }
}

struct ETOSAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartETOSAgentTaskIntent(),
            phrases: ["用 \(.applicationName) 新建 Agent 任务"],
            shortTitle: "新建 Agent 任务",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: SaveETOSMemoryIntent(),
            phrases: ["保存到 \(.applicationName) 记忆"],
            shortTitle: "保存记忆",
            systemImageName: "brain"
        )
        AppShortcut(
            intent: GetETOSTaskStatusIntent(),
            phrases: ["查看 \(.applicationName) Agent 状态"],
            shortTitle: "Agent 状态",
            systemImageName: "waveform.path.ecg"
        )
    }
}
