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

    private let storage: LocalLinuxStorageManager
    private var eventsByJobID: [UUID: [LocalLinuxBridgeDiagnosticEvent]] = [:]

    public init(storage: LocalLinuxStorageManager = .shared) {
        self.storage = storage
    }

    public func append(_ events: [LocalLinuxBridgeDiagnosticEvent], jobID: UUID) async {
        guard !events.isEmpty else { return }
        eventsByJobID[jobID, default: []].append(contentsOf: events)
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
            systemCallNumber: first.map(\.systemCallNumber),
            systemCallName: first?.systemCallName,
            occurrenceCount: max(1, events.count),
            outputRelativePath: job.outputRelativePath,
            redactedSummary: summary,
            createdAt: Date()
        )
        _ = Persistence.saveLocalLinuxDiagnostic(diagnostic)
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
