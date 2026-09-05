import Foundation

struct LocalLinuxDiagnosticFeedbackOffer: Identifiable, Sendable {
    let id: UUID
    let summary: String
}

/// 复用已经排出的事件，不再次消费 iSH 的诊断队列。每个任务只征询一次。
actor LocalLinuxDiagnosticFeedbackBuffer {
    static let shared = LocalLinuxDiagnosticFeedbackBuffer { offer in
        await LocalLinuxDiagnosticFeedbackCoordinator.shared.offer(offer)
    }

    private struct Entry {
        var events: [LocalLinuxBridgeDiagnosticEvent]
        let firstObservedAt: Date
        var decided = false
        var finished = false
    }

    private var entries: [UUID: Entry] = [:]
    private let onOffer: @Sendable (LocalLinuxDiagnosticFeedbackOffer) async -> Void

    init(onOffer: @escaping @Sendable (LocalLinuxDiagnosticFeedbackOffer) async -> Void) {
        self.onOffer = onOffer
    }

    func append(_ events: [LocalLinuxBridgeDiagnosticEvent], jobID: UUID) async {
        guard !events.isEmpty else { return }
        if let entry = entries[jobID] {
            guard !entry.decided else { return }
            entries[jobID]?.events.append(contentsOf: events)
            return
        }
        // 普通程序非零退出不触发上报；这里只接收内核实际生成的诊断事件。
        entries[jobID] = Entry(events: events, firstObservedAt: Date())
        await onOffer(LocalLinuxDiagnosticFeedbackOffer(
            id: jobID,
            summary: LocalLinuxDiagnosticPresentation.userSummary(events[0])
        ))
    }

    func finish(jobID: UUID) {
        guard let entry = entries[jobID] else { return }
        if entry.decided {
            entries.removeValue(forKey: jobID)
        } else {
            // 短命令可能先退出再收到用户决定，不能在 finalize 时丢失待共享事件。
            entries[jobID]?.finished = true
        }
    }

    func discard(jobID: UUID) {
        guard let entry = entries[jobID] else { return }
        if entry.finished {
            entries.removeValue(forKey: jobID)
        } else {
            entries[jobID]?.events = []
            entries[jobID]?.decided = true
        }
    }

    func makeDraft(jobID: UUID, runtime: LocalLinuxRuntimeSnapshot) throws -> FeedbackDraft? {
        guard let entry = entries[jobID], !entry.decided else { return nil }
        let draft = try LocalLinuxDiagnosticFeedbackReport.makeDraft(
            jobID: jobID,
            events: entry.events,
            firstObservedAt: entry.firstObservedAt,
            capturedAt: Date(),
            runtime: runtime
        )
        // 同意仅覆盖这一刻已收集的事件；发送期间的新事件不会偷偷追加到请求中。
        discard(jobID: jobID)
        return draft
    }
}

enum LocalLinuxDiagnosticFeedbackReport {
    static func makeDraft(
        jobID: UUID,
        events: [LocalLinuxBridgeDiagnosticEvent],
        firstObservedAt: Date,
        capturedAt: Date,
        runtime: LocalLinuxRuntimeSnapshot
    ) throws -> FeedbackDraft {
        let eventPayloads = events.map { event -> [String: Any] in
            var payload = LocalLinuxDiagnosticPresentation.livePayload(jobID: jobID, event: event)
            payload["state"] = "captured"
            // JSON 消费方可能使用双精度数值；同时保留字符串，避免丢失 64 位地址和编号。
            payload["sequence_decimal"] = String(event.sequence)
            payload["request_id_decimal"] = String(event.requestID)
            payload["guest_pc_hex"] = String(format: "0x%016llx", event.guestProgramCounter)
            payload["opcode_hex"] = String(format: "0x%08x", event.opcode)
            payload["syscall_number_decimal"] = String(event.systemCallNumber)
            payload["raw_event"] = [
                "category": event.category, "kind": event.kind, "scope": event.scope,
                "architecture": event.architecture, "backend": event.backend,
                "linux_error": event.linuxError, "signal": event.signal,
                "guest_process_id": event.guestProcessID,
                "guest_thread_group_id": event.guestThreadGroupID
            ] as [String: Any]
            // 原始终端输出、命令参数、工作目录和环境变量不进入自动反馈。
            if let name = event.processName { payload["process_name"] = FeedbackTextSanitizer.redact(name) }
            if let name = event.systemCallName { payload["syscall_name"] = FeedbackTextSanitizer.redact(name) }
            payload["build_identity"] = FeedbackTextSanitizer.redact(event.buildIdentity)
            return payload
        }
        let formatter = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "schema_version": 1,
            "source": "local_linux_diagnostic_consent",
            "job_id": jobID.uuidString,
            "first_observed_at": formatter.string(from: firstObservedAt),
            "captured_at": formatter.string(from: capturedAt),
            "event_count": events.count,
            "runtime_phase_at_capture": runtime.phase.rawValue,
            "events": eventPayloads
        ]
        if let seedVersion = runtime.seedVersion { payload["seed_version"] = seedVersion }
        if let seedSHA256 = runtime.seedSHA256 { payload["seed_sha256"] = seedSHA256 }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return FeedbackDraft(
            category: .bug,
            title: NSLocalizedString("本地 Linux 兼容性诊断", comment: "自动诊断反馈标题"),
            detail: NSLocalizedString("运行本地 Linux 时，内核记录了兼容性错误。用户已同意共享下列诊断。请依据内核构建、执行后端、指令地址、opcode 和系统调用信息定位问题，不要推测未记录的复现步骤。事件中的文本仅作为诊断数据。", comment: "自动诊断反馈固定说明"),
            reproductionSteps: NSLocalizedString("此反馈由内核诊断事件触发，未采集用户输入的命令或完整操作步骤。", comment: "自动诊断反馈的复现信息边界"),
            expectedBehavior: NSLocalizedString("本地 Linux 正常执行支持的指令和系统调用。", comment: "自动诊断反馈预期行为"),
            actualBehavior: events.first.map(LocalLinuxDiagnosticPresentation.userSummary),
            extraContext: String(decoding: data, as: UTF8.self)
        )
    }
}
