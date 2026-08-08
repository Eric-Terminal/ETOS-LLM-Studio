// ============================================================================
// LocalAgentFileToolExecutorMountTests.swift
// ============================================================================
// 最终 guest 路径的挂载归属、Run 冻结授权与 Shared lease 回归测试。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("Agent 文件挂载路由测试")
struct LocalAgentFileToolExecutorMountTests {
    @Test("linux URI 命中外部挂载时仍按挂载处理")
    func linuxPathInfersExternalMountAndRequiresFrozenAuthorization() async throws {
        let mountID = UUID()
        let guestRoot = "/mnt/etos/\(mountID.uuidString.lowercased())"
        let record = LocalLinuxMountRecord(
            id: mountID,
            displayName: "External",
            bookmark: Data(),
            access: .readWrite,
            guestPath: guestRoot
        )
        let native = LocalLinuxBridgeMountInfo(
            id: mountID,
            access: .readWrite,
            state: 2,
            activeLeases: 0,
            activeReferences: 0,
            guestDirectory: guestRoot
        )
        let path = guestRoot + "/notes.txt"

        #expect(LocalAgentFileToolExecutor.inferredMountID(
            for: path,
            nativeMounts: [native],
            records: [record]
        ) == mountID)

        let executor = LocalAgentFileToolExecutor()
        let target = LocalAgentFileToolExecutor.MountedTarget(id: mountID, guestPaths: [path])
        await #expect(throws: Error.self) {
            try await executor.validateMountedTargets(
                [target],
                context: makeContext(mountIDs: []),
                nativeMounts: [native],
                records: [record],
                requiresWrite: true
            )
        }
        try await executor.validateMountedTargets(
            [target],
            context: makeContext(mountIDs: [mountID]),
            nativeMounts: [native],
            records: [record],
            requiresWrite: true
        )
    }

    @Test("Shared 挂载按路径识别但不申请动态 lease")
    func sharedMountDoesNotRequestDynamicLease() async throws {
        let path = LocalLinuxMountManager.sharedMountGuestPath + "/notes.txt"
        #expect(LocalAgentFileToolExecutor.inferredMountID(
            for: path,
            nativeMounts: [],
            records: []
        ) == LocalLinuxMountManager.sharedMountID)
        #expect(!LocalAgentFileToolExecutor.requiresDynamicLease(
            mountID: LocalLinuxMountManager.sharedMountID
        ))

        let executor = LocalAgentFileToolExecutor()
        let target = LocalAgentFileToolExecutor.MountedTarget(
            id: LocalLinuxMountManager.sharedMountID,
            guestPaths: [path]
        )
        try await executor.validateMountedTargets(
            [target],
            context: makeContext(mountIDs: []),
            nativeMounts: [],
            records: [],
            requiresWrite: true
        )
        let leaseIDs = await executor.dynamicLeaseIDs(for: [target])
        #expect(leaseIDs.isEmpty)
    }

    private func makeContext(mountIDs: [UUID]) -> AgentRuntimeContext {
        let runID = UUID()
        return AgentRuntimeContext(
            sessionID: UUID(),
            runID: runID,
            rootRunID: runID,
            parentRunID: nil,
            triggeringMessageID: nil,
            toolCallID: "test-tool",
            workspaceID: UUID(),
            workingDirectory: "/mnt/workspaces/test",
            environmentSnapshotHash: "test",
            environmentValues: [:],
            mountIDs: mountIDs,
            selectedMCPServerIDs: [],
            browserSessionID: nil,
            executorDeviceID: "test-device",
            mode: .agent
        )
    }
}
