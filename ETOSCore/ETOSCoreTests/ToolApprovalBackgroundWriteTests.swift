import Foundation
import Testing
@testable import ETOSCore

@Suite("后台审批配置", .serialized)
struct ToolApprovalBackgroundWriteTests {
    @Test("关闭自动批准提交前暂停计时，保存失败也不自动恢复当前倒计时")
    @MainActor
    func pendingAndFailedWriteStopsCountdown() async throws {
        let gate = ToolApprovalWriteGate()
        let initial = ToolApprovalPreferences(enabled: true, countdown: 30, disabledTools: [])
        let worker = ToolApprovalSettingsWorker(read: { initial }, save: { _ in
            gate.entered.signal()
            guard gate.release.wait(timeout: .now() + 5) == .success else { throw ToolApprovalSettingsError.persistenceFailed }
            throw ToolApprovalSettingsError.persistenceFailed
        })
        let center = ToolPermissionCenter(defaults: .standard, preferences: initial, settingsWorker: worker)
        let requestTask = Task { await center.requestPermission(toolName: "fixture", displayName: nil, arguments: "{}") }
        defer { requestTask.cancel() }
        let request = try await activeRequest(center)
        #expect(center.autoApproveRemainingSeconds(for: request) == 30)
        let write = Task { try await center.updatePreferencesInBackground(.enabled(false)) }
        let entered = await Task.detached { gate.entered.wait(timeout: .now() + 5) == .success }.value
        #expect(entered)
        #expect(center.autoApproveRemainingSeconds(for: request) == nil)
        gate.release.signal()
        do { try await write.value; Issue.record("应报告数据库写入失败") } catch {}
        #expect(center.autoApproveEnabled)
        #expect(center.activeRequest?.id == request.id)
        #expect(center.autoApproveRemainingSeconds(for: request) == nil)
        center.resolveRequest(withID: request.id, decision: .deny)
        #expect(await requestTask.value == .deny)
    }

    @Test("后台开启自动批准不能绕过强制确认")
    @MainActor
    func forcedRequestsNeverStartCountdown() async throws {
        let initial = ToolApprovalPreferences(enabled: false, countdown: 8, disabledTools: [])
        let saved = ToolApprovalPreferences(enabled: true, countdown: 1, disabledTools: [])
        let worker = ToolApprovalSettingsWorker(read: { initial }, save: { _ in saved })
        let center = ToolPermissionCenter(defaults: .standard, preferences: initial, settingsWorker: worker)
        let task = Task { await center.requestPermission(toolName: "forced", displayName: nil, arguments: "{}", forcePrompt: true) }
        defer { task.cancel() }
        let request = try await activeRequest(center)
        try await center.updatePreferencesInBackground(.automation(enabled: true, countdown: 1))
        #expect(center.autoApproveEnabled)
        #expect(center.autoApproveRemainingSeconds(for: request) == nil)
        #expect(center.activeRequest?.id == request.id)
        center.resolveRequest(withID: request.id, decision: .allowOnce)
        #expect(await task.value == .allowOnce)
    }

    @Test("恢复配置清除本次运行的完全权限，读取失败时停止自动批准")
    @MainActor
    func reloadDoesNotCarryOldGrants() async throws {
        let initial = ToolApprovalPreferences(enabled: true, countdown: 30, disabledTools: [])
        let worker = ToolApprovalSettingsWorker(read: { throw ToolApprovalSettingsError.persistenceFailed }, save: { _ in initial })
        let center = ToolPermissionCenter(defaults: .standard, preferences: initial, settingsWorker: worker)
        let first = Task { await center.requestPermission(toolName: "first", displayName: nil, arguments: "{}") }
        defer { first.cancel() }
        let request = try await activeRequest(center)
        center.resolveRequest(withID: request.id, decision: .allowAll)
        #expect(await first.value == .allowAll)
        do { try await center.reloadPreferencesInBackground(); Issue.record("应报告配置读取失败") } catch {}
        #expect(!center.autoApproveEnabled)
        let next = Task { await center.requestPermission(toolName: "second", displayName: nil, arguments: "{}") }
        defer { next.cancel() }
        let pending = try await activeRequest(center)
        #expect(pending.toolName == "second")
        center.resolveRequest(withID: pending.id, decision: .deny)
        #expect(await next.value == .deny)
    }

    @MainActor
    private func activeRequest(_ center: ToolPermissionCenter) async throws -> ToolPermissionRequest {
        for _ in 0..<100 {
            if let request = center.activeRequest { return request }
            await Task.yield()
        }
        return try #require(center.activeRequest)
    }
}

private final class ToolApprovalWriteGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
}
