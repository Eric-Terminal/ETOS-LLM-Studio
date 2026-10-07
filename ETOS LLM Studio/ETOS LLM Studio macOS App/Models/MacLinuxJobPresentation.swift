import ETOSCore
import Foundation

struct MacLinuxJobRow: Identifiable, Sendable {
    let job: LocalLinuxJob
    let title: String
    let kind: String
    let state: String
    let createdAt: String
    var id: UUID { job.id }

    init(_ job: LocalLinuxJob) {
        self.job = job; title = job.request.executable
        kind = job.kind.displayName; state = job.state.displayName
        createdAt = job.createdAt.formatted(date: .abbreviated, time: .standard)
    }
}

struct MacLinuxJobGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let runID: UUID?
    let hasActiveJobs: Bool
    let rows: [MacLinuxJobRow]
}

struct MacLinuxJobCatalog: Sendable {
    let groups: [MacLinuxJobGroup]
    let activeCount: Int
    let historyCount: Int
    let hasMore: Bool
    let watchedJobs: [LocalLinuxJob]
    let guideRows: JSONValue

    static func prepare(active: [LocalLinuxJob], history: [LocalLinuxJob], watched: [LocalLinuxJob], hasMore: Bool, sessionID: UUID?) -> Self {
        // 先按稳定 ID 合并，确保刚结束的活跃任务与随后读到的历史页不会重复。
        var jobs = Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for job in watched { jobs[job.id] = job }
        for job in active { jobs[job.id] = job }
        let groups = LocalLinuxJobScheduler.orderedJobGroups(Array(jobs.values)).map { group in
            let source = group[0]
            let session = sessionID == nil ? source.sessionID.map {
                String(format: NSLocalizedString("会话 %@ · ", comment: ""), String($0.uuidString.prefix(8)))
            } ?? "" : ""
            let title = source.runID.map { String(format: NSLocalizedString("Agent %@", comment: ""), String($0.uuidString.prefix(8))) }
                ?? NSLocalizedString("用户与长期进程", comment: "")
            return MacLinuxJobGroup(id: "\(source.sessionID?.uuidString ?? "device")/\(source.runID?.uuidString ?? "user")",
                title: session + title, runID: source.runID, hasActiveJobs: group.contains { !$0.state.isTerminal }, rows: group.map(MacLinuxJobRow.init))
        }
        let activeCount = jobs.values.filter { !$0.state.isTerminal }.count
        return Self(groups: groups, activeCount: activeCount, historyCount: jobs.count - activeCount,
            hasMore: hasMore, watchedJobs: active + watched,
            guideRows: .array(LocalLinuxJobScheduler.orderedJobs(Array(jobs.values)).map { job in .dictionary([
                "id": .string(job.id.uuidString), "kind": .string(job.kind.rawValue), "state": .string(job.state.rawValue),
                "session_id": .string(job.sessionID?.uuidString ?? ""), "run_id": .string(job.runID?.uuidString ?? "")
            ]) }))
    }

    static func load(sessionID: UUID?, pages: Int, watching: [LocalLinuxJob]) async throws -> Self {
        let services = await MacLinuxServices.shared.value
        var history: [LocalLinuxJob] = []
        var cursor: LocalLinuxJobCursor?
        for _ in 0..<pages {
            try Task.checkCancellation()
            let page = Persistence.loadLocalLinuxJobHistoryPage(sessionID: sessionID, cursor: cursor, limit: 50)
            history.append(contentsOf: page.jobs); cursor = page.nextCursor
            if cursor == nil { break }
        }
        let active = await services.scheduler.activeJobs().filter { sessionID == nil || $0.sessionID == sessionID }
        let visibleIDs = Set((active + history).map(\.id))
        var watched: [UUID: LocalLinuxJob] = [:]
        // 很早启动的任务可能落在历史窗口以外；它结束时仍保留在当前页面，直到手动刷新。
        for previous in watching where !visibleIDs.contains(previous.id) {
            try Task.checkCancellation()
            if let current = await services.scheduler.job(id: previous.id) { watched[current.id] = current }
        }
        return prepare(active: active, history: history, watched: Array(watched.values), hasMore: cursor != nil, sessionID: sessionID)
    }
}

struct MacLinuxJobField: Identifiable, Sendable {
    let id: String
    let title: String
    let value: String
}

struct MacLinuxJobDetails: Sendable {
    let job: LocalLinuxJob
    let fields: [MacLinuxJobField]

    static func prepare(_ job: LocalLinuxJob) throws -> Self {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var fields = [MacLinuxJobField]()
        func add(_ id: String, _ title: String, _ value: String?) {
            if let value { fields.append(MacLinuxJobField(id: id, title: title, value: value)) }
        }
        add("id", NSLocalizedString("任务", comment: ""), job.id.uuidString)
        add("kind", NSLocalizedString("类型", comment: ""), job.kind.displayName)
        add("state", NSLocalizedString("状态", comment: ""), job.state.displayName)
        add("executable", NSLocalizedString("可执行文件", comment: ""), job.request.executable)
        add("arguments", NSLocalizedString("参数", comment: ""), String(decoding: try encoder.encode(job.request.arguments), as: UTF8.self))
        add("script", NSLocalizedString("脚本", comment: ""), job.request.shellScript)
        add("directory", NSLocalizedString("工作目录", comment: ""), job.request.workingDirectory ?? "/")
        add("session", NSLocalizedString("会话", comment: ""), job.sessionID?.uuidString)
        add("run", NSLocalizedString("Agent Run", comment: ""), job.runID?.uuidString)
        add("call", NSLocalizedString("工具调用", comment: ""), job.toolCallID)
        add("device", NSLocalizedString("执行设备", comment: ""), job.executorDeviceID)
        add("created", NSLocalizedString("创建时间", comment: ""), job.createdAt.formatted(date: .abbreviated, time: .standard))
        add("finished", NSLocalizedString("结束时间", comment: ""), job.finishedAt?.formatted(date: .abbreviated, time: .standard))
        add("reason", NSLocalizedString("完成原因", comment: ""), job.completionReason?.displayName)
        add("exit", NSLocalizedString("退出码", comment: ""), job.exitCode.map(String.init))
        add("signal", NSLocalizedString("信号", comment: ""), job.terminationSignal.map(String.init))
        add("errno", NSLocalizedString("Linux 错误码", comment: ""), job.linuxError.map(String.init))
        add("diagnostic", NSLocalizedString("诊断编号", comment: ""), job.diagnosticID?.uuidString)
        if let match = job.request.commandRuleMatch {
            add("rule", NSLocalizedString("规则", comment: ""), match.ruleName)
            add("matched", NSLocalizedString("匹配内容", comment: ""), match.matchedText)
            add("action", NSLocalizedString("处理", comment: ""), match.action.displayName)
        }
        add("stdout", NSLocalizedString("stdout", comment: ""), ByteCountFormatter.string(fromByteCount: Int64(clamping: job.stdoutBytes), countStyle: .file))
        add("stderr", NSLocalizedString("stderr", comment: ""), ByteCountFormatter.string(fromByteCount: Int64(clamping: job.stderrBytes), countStyle: .file))
        return Self(job: job, fields: fields)
    }
}

struct MacLinuxDiagnosticDetails: Sendable {
    let id: UUID
    let fields: [MacLinuxJobField]
    let json: String

    static func prepare(_ diagnostic: LinuxExecutionDiagnostic) throws -> Self {
        var fields = [MacLinuxJobField]()
        func add(_ id: String, _ title: String, _ value: String?) {
            if let value { fields.append(MacLinuxJobField(id: id, title: title, value: value)) }
        }
        add("id", NSLocalizedString("诊断编号", comment: ""), diagnostic.id.uuidString)
        add("summary", NSLocalizedString("摘要", comment: ""), diagnostic.redactedSummary)
        add("category", NSLocalizedString("类型", comment: ""), diagnostic.category.rawValue)
        add("architecture", NSLocalizedString("架构", comment: ""), diagnostic.guestArchitecture)
        add("backend", NSLocalizedString("执行后端", comment: ""), diagnostic.backend)
        add("build", NSLocalizedString("构建标识", comment: ""), diagnostic.buildIdentity)
        add("seed", NSLocalizedString("Alpine", comment: ""), diagnostic.seedVersion)
        add("count", NSLocalizedString("出现次数", comment: ""), String(diagnostic.occurrenceCount))
        add("reason", NSLocalizedString("完成原因", comment: ""), diagnostic.completionReason?.displayName)
        add("exit", NSLocalizedString("退出码", comment: ""), diagnostic.exitCode.map(String.init))
        add("signal", NSLocalizedString("信号", comment: ""), diagnostic.signal.map(String.init))
        add("errno", NSLocalizedString("Linux 错误码", comment: ""), diagnostic.linuxError.map(String.init))
        add("syscall", NSLocalizedString("系统调用", comment: ""), diagnostic.systemCallName)
        add("syscall_id", NSLocalizedString("系统调用编号", comment: ""), diagnostic.systemCallNumber.map(String.init))
        add("pc", NSLocalizedString("指令地址", comment: ""), diagnostic.guestProgramCounter.map { String(format: "0x%016llx", $0) })
        add("opcode", NSLocalizedString("指令编码", comment: ""), diagnostic.opcode.map { String(format: "0x%08x", $0) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return Self(id: diagnostic.id, fields: fields, json: String(decoding: try encoder.encode(diagnostic), as: UTF8.self))
    }
}
