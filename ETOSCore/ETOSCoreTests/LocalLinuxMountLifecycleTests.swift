import Foundation
import Testing
@testable import ETOSCore

@Suite("挂载状态切换与失败恢复", .serialized)
struct LocalLinuxMountLifecycleTests {
    @Test("即时挂载失败后重试不会留下重复记录")
    func failedAdditionDoesNotPersistRecords() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = MountBridgeStub(addError: -5)
        let manager = makeManager(root: root, bridge: bridge)
        let name = "失败重试-\(UUID().uuidString)"

        for _ in 0..<2 {
            await #expect(throws: LocalLinuxRuntimeError.self) {
                try await manager.addExternalDirectory(root, displayName: name, access: .readWrite)
            }
        }

        #expect(!Persistence.loadLocalLinuxMounts().contains { $0.displayName == name })
    }

    @Test("旧挂载被占用时重新授权失败，不覆盖旧书签与权限")
    func busyReauthorizationPreservesOriginalRecord() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try saveRecord(directory: root, access: .readOnly)
        defer { _ = Persistence.deleteLocalLinuxMount(id: original.id) }
        let replacement = root.appendingPathComponent("另一个目录", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let manager = makeManager(root: root, bridge: MountBridgeStub(removeError: -16))

        await #expect(throws: LocalLinuxRuntimeError.self) {
            try await manager.reauthorize(id: original.id, with: replacement, access: .readWrite)
        }

        #expect(Persistence.loadLocalLinuxMounts().first(where: { $0.id == original.id }) == original)
    }

    @Test("旧挂载移除后新挂载失败，保留旧配置并允许再次重新授权")
    func failedReplacementCanBeRetried() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try saveRecord(directory: root, access: .readOnly)
        defer { _ = Persistence.deleteLocalLinuxMount(id: original.id) }
        let replacement = root.appendingPathComponent("新目录", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let bridge = MountBridgeStub(addError: -5)
        let manager = makeManager(root: root, bridge: bridge)

        await #expect(throws: LocalLinuxRuntimeError.self) {
            try await manager.reauthorize(id: original.id, with: replacement, access: .readWrite)
        }
        let failed = try #require(Persistence.loadLocalLinuxMounts().first(where: { $0.id == original.id }))
        #expect(failed.bookmark == original.bookmark)
        #expect(failed.access == original.access)
        #expect(failed.authorizationState == .unavailable)

        await bridge.allowAddition()
        let updated = try await manager.reauthorize(id: original.id, with: replacement, access: .readWrite)
        #expect(updated.id == original.id)
        #expect(updated.guestPath == original.guestPath)
        #expect(updated.displayName == replacement.lastPathComponent)
        #expect(updated.access == .readWrite)
        #expect(updated.authorizationState == .available)
    }

    @Test("启动准备后原本有效的授权不会一直处于正在准备状态")
    func startupPreparationFinishesAuthorizationState() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try saveRecord(directory: root, access: .readOnly)
        defer { _ = Persistence.deleteLocalLinuxMount(id: original.id) }
        let manager = makeManager(root: root, bridge: MountBridgeStub())

        let prepared = try await manager.prepareStartupMounts()

        #expect(prepared.mounts.contains { $0.id == original.id })
        #expect(Persistence.loadLocalLinuxMounts().first(where: { $0.id == original.id })?.authorizationState == .available)
    }

    @Test("启用过程中的租约计数变化不会被旧记录覆盖")
    func enablingPreservesUpdatedLeaseCount() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try saveRecord(directory: root, access: .readOnly, enabled: false)
        defer { _ = Persistence.deleteLocalLinuxMount(id: original.id) }
        let bridge = MountBridgeStub(incrementLeaseOnAdd: true)
        let manager = makeManager(root: root, bridge: bridge)

        let updated = try await manager.setEnabled(true, id: original.id)

        #expect(updated.activeLeaseCount == 1)
        #expect(Persistence.loadLocalLinuxMounts().first(where: { $0.id == original.id })?.activeLeaseCount == 1)
    }

    @Test("重新授权等待内核期间不能交错删除同一记录")
    func concurrentRemovalDoesNotRaceReauthorization() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try saveRecord(directory: root, access: .readOnly)
        defer { _ = Persistence.deleteLocalLinuxMount(id: original.id) }
        let bridge = MountBridgeStub(pauseRemoval: true)
        let manager = makeManager(root: root, bridge: bridge)
        let task = Task {
            try await manager.reauthorize(id: original.id, with: root, access: .readWrite)
        }
        await bridge.waitForRemoval()

        await #expect(throws: LocalLinuxRuntimeError.self) {
            try await manager.delete(id: original.id, force: false)
        }
        await bridge.finishRemoval()
        let updated = try await task.value

        #expect(updated.access == .readWrite)
        #expect(Persistence.loadLocalLinuxMounts().contains { $0.id == original.id })
    }

    @Test("迟到的授权状态更新不能复活已删除的挂载")
    func authorizationUpdateDoesNotRecreateDeletedRecord() throws {
        let id = UUID()
        #expect(Persistence.updateLocalLinuxMountAuthorizationState(id: id, state: .available))
        #expect(!Persistence.loadLocalLinuxMounts().contains { $0.id == id })
    }

    private func makeManager(root: URL, bridge: MountBridgeStub) -> LocalLinuxMountManager {
        LocalLinuxMountManager(
            storage: LocalLinuxStorageManager(fileManager: NoCloudFileManager(), documentsDirectory: root, appGroupLayout: nil),
            bridge: bridge
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func saveRecord(directory: URL, access: LocalLinuxMountAccess, enabled: Bool = true) throws -> LocalLinuxMountRecord {
        let id = UUID()
        let record = LocalLinuxMountRecord(
            id: id,
            displayName: directory.lastPathComponent,
            bookmark: try LocalLinuxExternalDirectory.createBookmark(for: directory),
            access: access,
            guestPath: "/mnt/etos/\(id.uuidString.lowercased())",
            isEnabled: enabled
        )
        #expect(Persistence.saveLocalLinuxMount(record))
        return record
    }
}

private final class NoCloudFileManager: FileManager, @unchecked Sendable {
    override func url(forUbiquityContainerIdentifier containerIdentifier: String?) -> URL? { nil }
}

private actor MountBridgeStub: LocalLinuxMountBridge {
    private var addError: Int32?
    private let removeError: Int32?
    private let incrementLeaseOnAdd: Bool
    private let pauseRemoval: Bool
    private var removal: CheckedContinuation<Void, Never>?
    private var removalWaiter: CheckedContinuation<Void, Never>?

    init(addError: Int32? = nil, removeError: Int32? = nil, incrementLeaseOnAdd: Bool = false, pauseRemoval: Bool = false) {
        self.addError = addError
        self.removeError = removeError
        self.incrementLeaseOnAdd = incrementLeaseOnAdd
        self.pauseRemoval = pauseRemoval
    }

    func runtimePhase() -> Int32 { 2 }
    func mounts() -> [LocalLinuxBridgeMountInfo] { [] }
    func allowAddition() { addError = nil }

    func addMount(_ mount: LocalLinuxBridgeMount) throws {
        if let addError { throw LocalLinuxRuntimeError.bridgeFailure(operation: "添加测试挂载", linuxError: addError) }
        if incrementLeaseOnAdd { _ = Persistence.updateLocalLinuxMountLeaseCount(id: mount.id, delta: 1) }
    }

    func removeMount(id: UUID, force: Bool) async throws {
        if let removeError { throw LocalLinuxRuntimeError.bridgeFailure(operation: "移除测试挂载", linuxError: removeError) }
        if pauseRemoval {
            await withCheckedContinuation { continuation in
                removal = continuation
                removalWaiter?.resume()
                removalWaiter = nil
            }
        }
    }

    func waitForRemoval() async {
        if removal != nil { return }
        await withCheckedContinuation { removalWaiter = $0 }
    }

    func finishRemoval() {
        removal?.resume()
        removal = nil
    }

    func acquireMountLease(id: UUID) throws -> iSHAppleBridgeMountLease {
        throw LocalLinuxRuntimeError.bridgeFailure(operation: "测试挂载不提供原生租约", linuxError: -2)
    }
}
