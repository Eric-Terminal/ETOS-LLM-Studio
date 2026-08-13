// ============================================================================
// LocalLinuxDiagnosticsRecorder.swift
// ============================================================================
// ETOS LLM Studio
//
// iSH 原始兼容性事件持续写入设备本地 Diagnostics；任务完成时再生成一条
// 可供时间线、模型和内置反馈工具引用的脱敏结构化摘要。
// ============================================================================

import Foundation

public actor LocalLinuxDiagnosticsRecorder {
    public static let shared = LocalLinuxDiagnosticsRecorder()

    private struct RecentEvent {
        let jobID: UUID
        let event: LocalLinuxBridgeDiagnosticEvent
        let capturedAt: Date
        var diagnosticID: UUID?
    }

    private let storage: LocalLinuxStorageManager
    private var eventsByJobID: [UUID: [LocalLinuxBridgeDiagnosticEvent]] = [:]
    private var mostRecentEvent: RecentEvent?

    public init(storage: LocalLinuxStorageManager = .shared) {
        self.storage = storage
    }

    public func append(_ events: [LocalLinuxBridgeDiagnosticEvent], jobID: UUID) async {
        guard !events.isEmpty else { return }
        eventsByJobID[jobID, default: []].append(contentsOf: events)
        if let latest = events
            .filter({ $0.scope == 3 })
            .max(by: { $0.sequence < $1.sequence }) {
            mostRecentEvent = RecentEvent(
                jobID: jobID,
                event: latest,
                capturedAt: Date(),
                diagnosticID: nil
            )
        }
        do {
            let layout = try await storage.prepareLayout()
            let url = layout.diagnostics.appendingPathComponent("\(jobID.uuidString).ndjson")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let encoder = JSONEncoder()
            for event in events {
                var line = try encoder.encode(event)
                line.append(0x0a)
                try handle.write(contentsOf: line)
            }
        } catch {
            // 数据库摘要仍会保留；诊断附件写入失败不应掩盖原命令结果。
        }
    }

    public func latestEvent(jobID: UUID) -> LocalLinuxBridgeDiagnosticEvent? {
        eventsByJobID[jobID]?.last
    }

    /// 最近一次兼容性故障会短暂随下一次 Agent 请求发送，避免模型还要调用诊断工具。
    public func recentModelContext(maximumAge: TimeInterval = 10 * 60) -> String? {
        guard let mostRecentEvent,
              Date().timeIntervalSince(mostRecentEvent.capturedAt) <= maximumAge else {
            return nil
        }
        return LocalLinuxDiagnosticPresentation.modelContext(
            jobID: mostRecentEvent.jobID,
            event: mostRecentEvent.event,
            diagnosticID: mostRecentEvent.diagnosticID
        )
    }

    public func finalize(
        job: LocalLinuxJob,
        completionReason: LocalLinuxCompletionReason,
        exitCode: Int32?,
        signal: Int32?,
        linuxError: Int32?,
        runtime: LocalLinuxRuntimeSnapshot
    ) -> UUID? {
        let events = eventsByJobID.removeValue(forKey: job.id) ?? []
        guard !events.isEmpty || completionReason != .exited || exitCode != 0 else { return nil }
        let first = events.first
        let category = diagnosticCategory(
            rawCategory: first?.category,
            completionReason: completionReason,
            exitCode: exitCode
        )
        let id = UUID()
        let summary = diagnosticSummary(
            category: category,
            systemCallName: first?.systemCallName,
            exitCode: exitCode,
            signal: signal,
            linuxError: linuxError
        )
        let diagnostic = LinuxExecutionDiagnostic(
            id: id,
            jobID: job.id,
            requestID: job.requestID,
            category: category,
            executable: job.request.executable,
            arguments: job.request.arguments,
            workingDirectory: job.request.workingDirectory,
            guestArchitecture: runtime.capabilities?.guestArchitecture ?? "aarch64",
            backend: runtime.capabilities?.backend ?? "unknown",
            buildIdentity: first?.buildIdentity ?? "",
            seedVersion: runtime.seedVersion,
            exitCode: exitCode,
            signal: signal,
            linuxError: linuxError,
            completionReason: completionReason,
            guestProgramCounter: first.map(\.guestProgramCounter),
            opcode: first.map(\.opcode),
            guestProcessID: first.flatMap { $0.guestProcessID == 0 ? nil : $0.guestProcessID },
            guestThreadGroupID: first.flatMap { $0.guestThreadGroupID == 0 ? nil : $0.guestThreadGroupID },
            processName: first?.processName,
            systemCallNumber: first.map(\.systemCallNumber),
            systemCallName: first?.systemCallName,
            occurrenceCount: max(1, events.count),
            outputRelativePath: job.outputRelativePath,
            redactedSummary: summary,
            createdAt: Date()
        )
        _ = Persistence.saveLocalLinuxDiagnostic(diagnostic)
        if mostRecentEvent?.jobID == job.id {
            mostRecentEvent?.diagnosticID = id
        }
        return id
    }

    private func diagnosticCategory(
        rawCategory: UInt32?,
        completionReason: LocalLinuxCompletionReason,
        exitCode: Int32?
    ) -> LinuxExecutionDiagnosticCategory {
        switch rawCategory {
        case 1: return .unsupportedInstruction
        case 2: return .unsupportedSystemCall
        case 3: return .fileSystem
        case 4: return .bridge
        default:
            switch completionReason {
            case .timedOut: return .timedOut
            case .outputLimit: return .resource
            case .runtimeFailure: return .bridge
            default: return exitCode == 0 ? .bridge : .program
            }
        }
    }

    private func diagnosticSummary(
        category: LinuxExecutionDiagnosticCategory,
        systemCallName: String?,
        exitCode: Int32?,
        signal: Int32?,
        linuxError: Int32?
    ) -> String {
        var fields = ["category=\(category.rawValue)"]
        if let systemCallName { fields.append("syscall=\(systemCallName)") }
        if let exitCode { fields.append("exit=\(exitCode)") }
        if let signal, signal != 0 { fields.append("signal=\(signal)") }
        if let linuxError, linuxError != 0 { fields.append("errno=\(linuxError)") }
        return fields.joined(separator: ", ")
    }
}

enum LocalLinuxDiagnosticPresentation {
    private static let userSummaryByteLimit = 256
    private static let modelContextByteLimit = 768

    static func userSummary(_ event: LocalLinuxBridgeDiagnosticEvent) -> String {
        var fields: [(isOptional: Bool, value: String)] = [
            (false, "type=\(category(rawValue: event.category))")
        ]
        if let processName = compact(event.processName), !processName.isEmpty {
            fields.append((true, "process=\(processName)"))
        }
        if event.guestProcessID != 0 { fields.append((false, "pid=\(event.guestProcessID)")) }
        if event.signal != 0 { fields.append((false, "signal=\(signalName(event.signal))")) }
        if event.guestProgramCounter != 0 {
            fields.append((false, String(format: "pc=0x%016llx", event.guestProgramCounter)))
        }
        if event.opcode != 0 {
            fields.append((false, String(format: "opcode=0x%08x", event.opcode)))
        }
        if let systemCallName = compact(event.systemCallName), !systemCallName.isEmpty {
            fields.append((true, "syscall=\(systemCallName)(\(event.systemCallNumber))"))
        } else if event.systemCallNumber != 0 {
            fields.append((true, "syscall=\(event.systemCallNumber)"))
        }
        if event.linuxError != 0 { fields.append((true, "errno=\(event.linuxError)")) }
        fields.append((false, "backend=\(backend(rawValue: event.backend))"))
        if let buildIdentity = compact(event.buildIdentity, maximumLength: 32), !buildIdentity.isEmpty {
            fields.append((true, "build=\(buildIdentity)"))
        }
        let heading = NSLocalizedString("Linux 运行时诊断：", comment: "Linux terminal diagnostic heading")
        func render() -> String {
            "[\(heading) \(fields.map(\.value).joined(separator: " "))]"
        }
        while render().utf8.count > userSummaryByteLimit,
              let index = fields.lastIndex(where: \.isOptional) {
            fields.remove(at: index)
        }
        return render()
    }

    static func livePayload(
        jobID: UUID,
        event: LocalLinuxBridgeDiagnosticEvent,
        diagnosticID: UUID? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "state": diagnosticID == nil ? "live" : "stored",
            "job_id": jobID.uuidString,
            "request_id": event.requestID,
            "sequence": event.sequence,
            "category": category(rawValue: event.category),
            "kind": event.kind,
            "scope": scope(rawValue: event.scope),
            "guest_architecture": event.architecture == 1 ? "aarch64" : "unknown_\(event.architecture)",
            "backend": backend(rawValue: event.backend),
            "build_identity": event.buildIdentity,
            "guest_pc": event.guestProgramCounter,
            "opcode": event.opcode
        ]
        value["id"] = diagnosticID?.uuidString
        value["guest_process_id"] = event.guestProcessID == 0 ? nil : event.guestProcessID
        value["guest_thread_group_id"] = event.guestThreadGroupID == 0 ? nil : event.guestThreadGroupID
        value["process_name"] = event.processName
        value["signal"] = event.signal == 0 ? nil : event.signal
        value["linux_errno"] = event.linuxError == 0 ? nil : event.linuxError
        value["syscall_number"] = event.systemCallNumber == 0 ? nil : event.systemCallNumber
        value["syscall_name"] = event.systemCallName
        return value
    }

    static func modelContext(
        jobID: UUID,
        event: LocalLinuxBridgeDiagnosticEvent,
        diagnosticID: UUID?
    ) -> String? {
        var value = livePayload(jobID: jobID, event: event, diagnosticID: diagnosticID)
        let removableKeys = [
            "build_identity", "syscall_name", "process_name", "guest_thread_group_id",
            "request_id", "sequence", "state", "kind", "scope"
        ]
        for key in [nil] + removableKeys.map(Optional.some) {
            if let key { value.removeValue(forKey: key) }
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
                return nil
            }
            if data.count <= modelContextByteLimit {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    private static func category(rawValue: UInt32) -> String {
        switch rawValue {
        case 1: return LinuxExecutionDiagnosticCategory.unsupportedInstruction.rawValue
        case 2: return LinuxExecutionDiagnosticCategory.unsupportedSystemCall.rawValue
        case 3: return LinuxExecutionDiagnosticCategory.fileSystem.rawValue
        case 4: return LinuxExecutionDiagnosticCategory.bridge.rawValue
        default: return "unknown_\(rawValue)"
        }
    }

    private static func backend(rawValue: UInt32) -> String {
        switch rawValue {
        case 1: return "c"
        case 2: return "threaded"
        default: return "unknown_\(rawValue)"
        }
    }

    private static func scope(rawValue: UInt32) -> String {
        switch rawValue {
        case 1: return "runtime"
        case 2: return "command"
        case 3: return "terminal"
        case 4: return "guest_file"
        default: return "unknown_\(rawValue)"
        }
    }

    private static func signalName(_ signal: Int32) -> String {
        signal == 4 ? "SIGILL" : String(signal)
    }

    /// 进程名来自 guest 边界；终端摘要只保留单行可复制字符，完整值仍在 JSON 诊断中。
    private static func compact(_ value: String?, maximumLength: Int = 32) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.prefix(maximumLength).map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
                ? "_"
                : Character(String(scalar))
        }
        let result = String(scalars)
        return value.unicodeScalars.count > maximumLength ? result + "…" : result
    }
}
