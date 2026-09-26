import Foundation
import Testing
@testable import ETOSCore

@Suite("失效挂载的停用与移除", .serialized)
struct LocalLinuxMountRemovalTests {
    @Test("内核不存在的挂载可重复普通移除或强制移除", .enabled(if: iSHAppleBridgeAdapter.isAvailable))
    func missingNativeMountRemovalIsIdempotent() async throws {
        let id = UUID()
        let bridge = iSHAppleBridgeAdapter()

        // 直接调用真实桥接入口，不启动 Linux；随机 ID 从未加入原生挂载表。
        try await bridge.removeMount(id: id, force: false)
        try await bridge.removeMount(id: id, force: false)
        try await bridge.removeMount(id: id, force: true)

        #expect(!(try await bridge.mounts()).contains { $0.id == id })
    }

    @Test("移除无效挂载身份仍返回原始错误", .enabled(if: iSHAppleBridgeAdapter.isAvailable))
    func invalidNativeMountIDStillFails() async throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        do {
            try await iSHAppleBridgeAdapter().removeMount(id: id, force: false)
            Issue.record("无效身份的 EINVAL 不应被当成已经卸载")
        } catch LocalLinuxRuntimeError.bridgeFailure(_, let linuxError) {
            #expect(linuxError == -22)
        }
    }

    @Test("需要重新授权的记录可停用并移除，保留外部文件")
    func unavailableRecordCanBeDisabledAndDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("keep.txt")
        let contents = Data("保留用户文件".utf8)
        try contents.write(to: file)

        let id = UUID()
        let record = LocalLinuxMountRecord(
            id: id,
            displayName: "需要重新授权的目录",
            bookmark: try LocalLinuxExternalDirectory.createBookmark(for: directory),
            access: .readWrite,
            guestPath: "/mnt/etos/\(id.uuidString.lowercased())",
            authorizationState: .needsReauthorization
        )
        #expect(Persistence.saveLocalLinuxMount(record))
        defer { _ = Persistence.deleteLocalLinuxMount(id: id) }
        let manager = LocalLinuxMountManager()

        let disabled = try await manager.setEnabled(false, id: id)
        #expect(!disabled.isEnabled)
        #expect(disabled.authorizationState == .needsReauthorization)
        #expect(Persistence.loadLocalLinuxMounts().first(where: { $0.id == id })?.isEnabled == false)

        try await manager.delete(id: id, force: false)

        #expect(!Persistence.loadLocalLinuxMounts().contains { $0.id == id })
        #expect(try Data(contentsOf: file) == contents)
    }
}
