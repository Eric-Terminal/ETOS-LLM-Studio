// ============================================================================
// WatchSystemEntryAppIntents.swift
// ETOS LLM Studio Watch App
// ============================================================================

import AppIntents
import ETOSCore
import Foundation

struct WatchETOSSessionEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("会话", table: "Localizable")
    )
    static var defaultQuery = WatchETOSSessionEntityQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct WatchETOSSessionEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [WatchETOSSessionEntity] {
        let wanted = Set(identifiers)
        let sessions = await Task.detached(priority: .userInitiated) {
            Persistence.loadChatSessions()
        }.value
        return sessions
            .filter { wanted.contains($0.id) }
            .prefix(20)
            .map { WatchETOSSessionEntity(id: $0.id, name: String($0.name.prefix(80))) }
    }

    func suggestedEntities() async throws -> [WatchETOSSessionEntity] {
        let sessions = await Task.detached(priority: .userInitiated) {
            Persistence.loadChatSessions()
        }.value
        return sessions
            .prefix(20)
            .map { WatchETOSSessionEntity(id: $0.id, name: String($0.name.prefix(80))) }
    }

    func entities(matching string: String) async throws -> [WatchETOSSessionEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessions = await Task.detached(priority: .userInitiated) {
            Persistence.loadChatSessions()
        }.value
        return sessions
            .lazy
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .prefix(20)
            .map { WatchETOSSessionEntity(id: $0.id, name: String($0.name.prefix(80))) }
    }
}

struct StartWatchETOSAgentTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "新建 Agent 任务"
    static var description = IntentDescription("在手表的新会话中交给 ETOS Agent 处理。")

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
            ? NSLocalizedString("该任务已经接收，将继续使用原会话。", comment: "Idempotent watch Agent intent result")
            : NSLocalizedString("任务已交给 ETOS Agent。", comment: "Watch Agent intent success")
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct ContinueWatchETOSSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "继续指定会话"
    static var description = IntentDescription("把新消息发送到手表上的指定 ETOS 会话。")

    @Parameter(title: "会话") var session: WatchETOSSessionEntity
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
        return .result(dialog: IntentDialog(stringLiteral: NSLocalizedString("消息已发送。", comment: "Watch continue session intent result")))
    }
}

struct GetWatchETOSTaskStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "获取 Agent 状态"
    static var description = IntentDescription("查看手表上指定会话或最近任务的运行状态。")

    @Parameter(title: "会话") var session: WatchETOSSessionEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let result = try await SystemEntryCoordinator.shared.status(sessionID: session?.id)
        let status: String
        switch result.status {
        case .queued: status = NSLocalizedString("等待中", comment: "Queued watch task status")
        case .running: status = NSLocalizedString("运行中", comment: "Running watch task status")
        case .waitingForApproval: status = NSLocalizedString("等待批准", comment: "Waiting approval watch task status")
        case .waitingForInput: status = NSLocalizedString("等待输入", comment: "Waiting input watch task status")
        case .completed: status = NSLocalizedString("已完成", comment: "Completed watch task status")
        case .failed: status = NSLocalizedString("失败", comment: "Failed watch task status")
        case .cancelled: status = NSLocalizedString("已取消", comment: "Cancelled watch task status")
        }
        let message = String(
            format: NSLocalizedString("%@：%@", comment: "Watch Agent status intent result"),
            result.sessionName,
            status
        )
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct StopWatchETOSTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "停止 Agent 任务"
    static var description = IntentDescription("停止手表指定会话中正在运行的请求。")

    @Parameter(title: "会话") var session: WatchETOSSessionEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await SystemEntryCoordinator.shared.stop(sessionID: session.id)
        return .result(dialog: IntentDialog(stringLiteral: NSLocalizedString("已请求停止任务。", comment: "Stop watch task intent result")))
    }
}

struct SaveWatchETOSMemoryIntent: AppIntent {
    static var title: LocalizedStringResource = "保存到 ETOS 记忆"
    static var description = IntentDescription("把文本写入手表上的 ETOS 长期记忆。")

    @Parameter(title: "内容") var content: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await SystemEntryCoordinator.shared.saveMemory(
            content,
            shortcutName: NSLocalizedString("保存到 ETOS 记忆", comment: "Watch memory shortcut source")
        )
        return .result(dialog: IntentDialog(stringLiteral: NSLocalizedString("记忆已保存。", comment: "Save watch memory intent result")))
    }
}

struct SearchWatchETOSMemoryIntent: AppIntent {
    static var title: LocalizedStringResource = "搜索 ETOS 记忆"
    static var description = IntentDescription("在手表的本机长期记忆中搜索相关内容。")

    @Parameter(title: "关键词") var query: String
    @Parameter(title: "数量", default: 5) var limit: Int

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let items = try await SystemEntryCoordinator.shared.searchMemory(query, limit: limit)
        let summary = items.prefix(5).map { String($0.content.prefix(120)) }.joined(separator: "\n\n")
        let dialog = String(
            format: NSLocalizedString("找到 %d 条记忆。", comment: "Watch memory search result count"),
            items.count
        )
        return .result(value: summary, dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct WatchETOSAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWatchETOSAgentTaskIntent(),
            phrases: ["用 \(.applicationName) 新建 Agent 任务"],
            shortTitle: "新建 Agent 任务",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: SaveWatchETOSMemoryIntent(),
            phrases: ["保存到 \(.applicationName) 记忆"],
            shortTitle: "保存记忆",
            systemImageName: "brain"
        )
        AppShortcut(
            intent: GetWatchETOSTaskStatusIntent(),
            phrases: ["查看 \(.applicationName) Agent 状态"],
            shortTitle: "Agent 状态",
            systemImageName: "waveform.path.ecg"
        )
    }
}
