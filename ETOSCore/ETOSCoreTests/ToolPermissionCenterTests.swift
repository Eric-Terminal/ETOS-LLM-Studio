// ============================================================================
// ToolPermissionCenterTests.swift
// ============================================================================
// 工具审批请求身份、队列推进与取消传播回归测试。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("工具审批中心测试", .serialized)
struct ToolPermissionCenterTests {
    @MainActor
    @Test("迟到决定不会作用于下一条排队请求")
    func staleDecisionCannotResolveNextRequest() async throws {
        let center = try makeCenter()
        let firstTask = Task {
            await center.requestPermission(
                toolName: "first_tool",
                displayName: nil,
                arguments: "{}"
            )
        }
        let firstRequest = try await requireActiveRequest(in: center)

        let secondTask = Task {
            await center.requestPermission(
                toolName: "second_tool",
                displayName: nil,
                arguments: "{}"
            )
        }
        await Task.yield()

        #expect(center.resolveRequest(withID: firstRequest.id, decision: .allowOnce))
        #expect(await firstTask.value == .allowOnce)
        let secondRequest = try await requireActiveRequest(in: center)
        #expect(secondRequest.toolName == "second_tool")

        #expect(!center.resolveRequest(withID: firstRequest.id, decision: .deny))
        #expect(center.activeRequest?.id == secondRequest.id)
        #expect(center.resolveRequest(withID: secondRequest.id, decision: .allowOnce))
        #expect(await secondTask.value == .allowOnce)
    }

    @MainActor
    @Test("取消等待审批的任务会立即移除请求")
    func cancellationRemovesPendingRequest() async throws {
        let center = try makeCenter()
        let task = Task {
            await center.requestPermission(
                toolName: "cancelled_tool",
                displayName: nil,
                arguments: "{}"
            )
        }
        _ = try await requireActiveRequest(in: center)

        task.cancel()
        #expect(await task.value == .deny)
        for _ in 0..<20 where center.activeRequest != nil {
            await Task.yield()
        }
        #expect(center.activeRequest == nil)
    }

    @MainActor
    @Test("取消排队审批只移除对应请求")
    func cancellationRemovesOnlyQueuedRequest() async throws {
        let center = try makeCenter()
        let activeTask = Task {
            await center.requestPermission(
                toolName: "active_tool",
                displayName: nil,
                arguments: "{}"
            )
        }
        let activeRequest = try await requireActiveRequest(in: center)
        let queuedTask = Task {
            await center.requestPermission(
                toolName: "queued_tool",
                displayName: nil,
                arguments: "{}"
            )
        }
        await Task.yield()

        queuedTask.cancel()
        #expect(await queuedTask.value == .deny)
        #expect(center.activeRequest?.id == activeRequest.id)
        #expect(center.resolveRequest(withID: activeRequest.id, decision: .allowOnce))
        #expect(await activeTask.value == .allowOnce)
        #expect(center.activeRequest == nil)
    }

    @MainActor
    private func makeCenter() throws -> ToolPermissionCenter {
        let suiteName = "ToolPermissionCenterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return ToolPermissionCenter(defaults: defaults)
    }

    @MainActor
    private func requireActiveRequest(
        in center: ToolPermissionCenter
    ) async throws -> ToolPermissionRequest {
        for _ in 0..<20 {
            if let request = center.activeRequest {
                return request
            }
            await Task.yield()
        }
        return try #require(center.activeRequest)
    }
}
