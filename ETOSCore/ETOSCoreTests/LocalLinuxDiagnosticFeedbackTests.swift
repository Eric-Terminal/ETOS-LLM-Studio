import Foundation
import Testing
@testable import ETOSCore

@Suite("本地 Linux 诊断共享")
struct LocalLinuxDiagnosticFeedbackTests {
    private actor Offers {
        var values: [LocalLinuxDiagnosticFeedbackOffer] = []
        func append(_ offer: LocalLinuxDiagnosticFeedbackOffer) { values.append(offer) }
    }

    private actor RuntimeSnapshots {
        var readCount = 0
        func read() -> LocalLinuxRuntimeSnapshot {
            readCount += 1
            return .init(phase: .ready)
        }
    }

    private static func event(sequence: UInt64 = 1, category: UInt32 = 1) -> LocalLinuxBridgeDiagnosticEvent {
        LocalLinuxBridgeDiagnosticEvent(
            category: category, kind: 1, scope: 3, architecture: 1, backend: 2,
            linuxError: -38, signal: 4, opcode: 0xd503201f,
            sequence: sequence, requestID: UInt64.max,
            guestProgramCounter: 0xffff_ffff_ffff_fffc, systemCallNumber: 435,
            guestProcessID: 101, guestThreadGroupID: 100,
            processName: "python3", systemCallName: "clone3", buildIdentity: "test-ish-build"
        )
    }

    @Test("空事件不提示，同一任务的多批诊断合并且退出后仍可共享")
    func batchesSurviveCompletion() async throws {
        let offers = Offers()
        let buffer = LocalLinuxDiagnosticFeedbackBuffer { await offers.append($0) }
        let jobID = UUID()
        await buffer.append([], jobID: jobID)
        #expect(await offers.values.isEmpty)
        await buffer.append([Self.event()], jobID: jobID)
        await buffer.append((2...6).map { Self.event(sequence: UInt64($0), category: 2) }, jobID: jobID)
        await buffer.finish(jobID: jobID)
        #expect(await offers.values.count == 1)
        let draft = try #require(try await buffer.makeDraft(jobID: jobID, runtime: .init(phase: .ready)))
        let payload = try Self.payload(draft)
        #expect(payload["event_count"] as? Int == 6)
        #expect((payload["events"] as? [[String: Any]])?.count == 6)
        #expect(try await buffer.makeDraft(jobID: jobID, runtime: .init(phase: .ready)) == nil)
    }

    @Test("完整诊断保留精确地址和编号，不收集命令及环境秘密")
    func reportPreservesDiagnosticFields() throws {
        let draft = try LocalLinuxDiagnosticFeedbackReport.makeDraft(
            jobID: UUID(), events: [Self.event()],
            firstObservedAt: Date(timeIntervalSince1970: 1), capturedAt: Date(timeIntervalSince1970: 2),
            runtime: .init(phase: .ready, seedVersion: "alpine-test", lastError: "api_key=should-not-be-shared")
        )
        let payload = try Self.payload(draft)
        let events = try #require(payload["events"] as? [[String: Any]])
        #expect(events[0]["request_id_decimal"] as? String == String(UInt64.max))
        #expect(events[0]["guest_pc_hex"] as? String == "0xfffffffffffffffc")
        #expect(events[0]["opcode_hex"] as? String == "0xd503201f")
        #expect(events[0]["syscall_number_decimal"] as? String == "435")
        #expect(events[0]["build_identity"] as? String == "test-ish-build")
        #expect(events[0]["guest_thread_group_id"] as? Int == 100)
        #expect(payload["seed_version"] as? String == "alpine-test")
        let context = draft.extraContext ?? ""
        for excludedKey in ["arguments", "environment", "working_directory", "output", "last_error"] {
            #expect(!context.contains("\"\(excludedKey)\""))
        }
        #expect(!context.contains("should-not-be-shared"))
        #expect(draft.isValid)
    }

    @Test("guest 提供的文本按现有反馈规则脱敏，JSON 仍可解析")
    func guestTextIsRedacted() throws {
        let event = LocalLinuxBridgeDiagnosticEvent(
            category: 1, kind: 1, scope: 2, architecture: 1, backend: 1,
            linuxError: 0, signal: 4, opcode: 0, sequence: 1, requestID: 1,
            guestProgramCounter: 0, systemCallNumber: 0,
            guestProcessID: 1, guestThreadGroupID: 1,
            processName: "sk-123456789012", systemCallName: nil, buildIdentity: "test-build"
        )
        let draft = try LocalLinuxDiagnosticFeedbackReport.makeDraft(
            jobID: UUID(), events: [event], firstObservedAt: Date(), capturedAt: Date(), runtime: .init(phase: .ready)
        )
        let payload = try Self.payload(draft)
        let events = try #require(payload["events"] as? [[String: Any]])
        #expect(events[0]["process_name"] as? String == "***")
        #expect(!(draft.extraContext ?? "").contains("sk-123456789012"))
    }

    @Test("尚未允许或明确拒绝时不会调用发送接口，同一终端不再追问")
    @MainActor
    func consentIsRequired() async throws {
        let offers = Offers()
        let buffer = LocalLinuxDiagnosticFeedbackBuffer { await offers.append($0) }
        var submissions = 0
        let snapshots = RuntimeSnapshots()
        let coordinator = LocalLinuxDiagnosticFeedbackCoordinator(
            buffer: buffer,
            runtimeSnapshot: { await snapshots.read() },
            submit: { _ in submissions += 1; return 42 }
        )
        let jobID = UUID()
        await buffer.append([Self.event()], jobID: jobID)
        let offer = try #require(await offers.values.first)
        coordinator.offer(offer)
        #expect(submissions == 0)
        let prompt = try #require(coordinator.prompt)
        await coordinator.dismiss(promptID: prompt.id)?.value
        await buffer.append([Self.event(sequence: 2)], jobID: jobID)
        #expect(await offers.values.count == 1)
        #expect(submissions == 0)
        #expect(coordinator.prompt == nil)
        #expect(await snapshots.readCount == 0)
        #expect(try await buffer.makeDraft(jobID: jobID, runtime: .init(phase: .ready)) == nil)
    }

    @Test("允许后只发送一次，失败重试保留原始报告且不追加新事件")
    @MainActor
    func retryUsesConsentedSnapshot() async throws {
        let offers = Offers()
        let buffer = LocalLinuxDiagnosticFeedbackBuffer { await offers.append($0) }
        var submitted: [FeedbackDraft] = []
        let coordinator = LocalLinuxDiagnosticFeedbackCoordinator(
            buffer: buffer,
            runtimeSnapshot: { .init(phase: .ready) },
            submit: { draft in
                submitted.append(draft)
                if submitted.count == 1 { throw URLError(.notConnectedToInternet) }
                return 42
            }
        )
        let jobID = UUID()
        await buffer.append([Self.event()], jobID: jobID)
        coordinator.offer(try #require(await offers.values.first))
        let consent = try #require(coordinator.prompt)
        let firstSend = coordinator.send(promptID: consent.id)
        #expect(coordinator.send(promptID: consent.id) == nil)
        await firstSend?.value
        let failure = try #require(coordinator.prompt)
        guard case .failed = failure.kind else { Issue.record("应保留发送失败状态供用户重试"); return }
        await buffer.append([Self.event(sequence: 2)], jobID: jobID)
        await buffer.finish(jobID: jobID)
        await coordinator.send(promptID: failure.id)?.value
        #expect(submitted.count == 2)
        #expect(submitted[0] == submitted[1])
        #expect(try Self.payload(submitted[1])["event_count"] as? Int == 1)
        let success = try #require(coordinator.prompt)
        guard case .sent(let number) = success.kind else { Issue.record("发送成功应显示工单编号"); return }
        #expect(number == 42)
        #expect(await offers.values.count == 1)
    }

    @Test("最上层终端承接弹窗，其他错误暂缓共享而不回退到被遮挡的根页")
    @MainActor
    func presenterOwnership() {
        let coordinator = LocalLinuxDiagnosticFeedbackCoordinator(submit: { _ in 42 })
        let root = UUID()
        let terminal = UUID()
        coordinator.registerPresenter(id: root, priority: 0, blocked: false)
        coordinator.registerPresenter(id: terminal, priority: 2, blocked: false)
        #expect(coordinator.presenterID == terminal)
        coordinator.registerPresenter(id: terminal, priority: 2, blocked: true)
        #expect(coordinator.presenterID == nil)
        coordinator.unregisterPresenter(id: terminal)
        #expect(coordinator.presenterID == root)
        coordinator.unregisterPresenter(id: root)
        #expect(coordinator.presenterID == nil)
    }

    private static func payload(_ draft: FeedbackDraft) throws -> [String: Any] {
        let text = try #require(draft.extraContext)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
