import Foundation
import Testing
@testable import ETOSCore

// 桥接替身覆盖恢复与失败路径；系统签发的安全作用域仍需真机补测：目录移动后
// 重启 App、云目录暂时离线后再次执行，以及写入文件是否出现在“文件”App 中。
@Suite("挂载状态切换与失败恢复", .serialized)
struct LocalLinuxMountLifecycleTests {
    @Test("旧目录确认不能切换、重新授权或删除后来修改的挂载")
    func staleConfirmationRejectsMutations() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try saveRecord(directory: root, access: .readOnly, enabled: false)
        defer { _ = Persistence.deleteLocalLinuxMount(id: saved.id) }
        let original = try #require(Persistence.loadLocalLinuxMounts().first { $0.id == saved.id })
        var changed = original; changed.displayName = "另一个目录配置"
        try #require(Persistence.saveLocalLinuxMount(changed))
        let manager = makeManager(root: root, bridge: MountBridgeStub())
        await #expect(throws: LocalLinuxRuntimeError.self) { try await manager.setEnabled(true, id: saved.id, expected: original) }
        await #expect(throws: LocalLinuxRuntimeError.self) { try await manager.reauthorize(id: saved.id, with: root, access: .readWrite, expected: original) }
        await #expect(throws: LocalLinuxRuntimeError.self) { try await manager.delete(id: saved.id, force: true, expected: original) }
        #expect(Persistence.loadLocalLinuxMounts().first { $0.id == saved.id } == changed)
    }

    @Test("租约和授权探测更新不会撤销同一目录的确认")
    func dynamicStatusKeepsConfigurationIdentity() {
        let original = LocalLinuxMountRecord(displayName: "目录", bookmark: Data([1]), access: .readOnly, guestPath: "/mnt/test")
        var current = original; current.activeLeaseCount = 9; current.authorizationState = .materializing; current.updatedAt = Date()
        #expect(current.matchesConfiguration(original))
        current.bookmark = Data([2])
        #expect(!current.matchesConfiguration(original))
        current = original; current.access = .readWrite
        #expect(!current.matchesConfiguration(original))
    }

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
        let saved = try saveRecord(directory: root, access: .readOnly)
        defer { _ = Persistence.deleteLocalLinuxMount(id: saved.id) }
        // 用持久化后的记录作基线，排除 Date 首次转换 Unix 时间戳时的浮点舍入。
        let original = try #require(Persistence.loadLocalLinuxMounts().first(where: { $0.id == saved.id }))
        #expect(original.bookmark == saved.bookmark)
        #expect(original.access == saved.access)
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

    @Test("取得租约时自动恢复内核缺失的已授权挂载")
    func missingMountIsRestoredBeforeLease() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try saveRecord(directory: root, access: .readWrite)
        defer { _ = Persistence.deleteLocalLinuxMount(id: saved.id) }
        _ = Persistence.updateLocalLinuxMountAuthorizationState(id: saved.id, state: .unavailable)
        let bridge = MountBridgeStub()
        let manager = makeManager(root: root, bridge: bridge)

        let leases = try await manager.acquireLeases(ids: [saved.id])

        #expect(leases.map(\.mountID) == [saved.id])
        #expect(await bridge.addedIDs == [saved.id])
        #expect(await bridge.leaseAttempts == [saved.id, saved.id])
        let restored = try #require(Persistence.loadLocalLinuxMounts().first { $0.id == saved.id })
        #expect(restored.authorizationState == .available)
        #expect(restored.activeLeaseCount == 1)
        #expect(restored.guestPath == saved.guestPath)
        #expect(restored.access == saved.access)

        try await manager.mountNow(id: saved.id)
        #expect(await bridge.addedIDs == [saved.id])
        leases.forEach { $0.release() }
    }

    @Test("恢复失败不会取得租约或把目录标记为可用")
    func failedMountRecoveryStopsLeaseAcquisition() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try saveRecord(directory: root, access: .readWrite)
        defer { _ = Persistence.deleteLocalLinuxMount(id: saved.id) }
        let bridge = MountBridgeStub(addError: -5)
        let manager = makeManager(root: root, bridge: bridge)

        await #expect(throws: LocalLinuxRuntimeError.self) {
            _ = try await manager.acquireLeases(ids: [saved.id])
        }

        #expect(await bridge.leaseAttempts == [saved.id])
        #expect(Persistence.loadLocalLinuxMounts().first { $0.id == saved.id }?.authorizationState == .unavailable)
        #expect(Persistence.loadLocalLinuxMounts().first { $0.id == saved.id }?.activeLeaseCount == 0)
    }

    @Test("租约恢复不能复活已停用或已删除的目录")
    func leaseRecoveryHonorsDisabledAndDeletedMounts() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try saveRecord(directory: root, access: .readWrite, enabled: false)
        defer { _ = Persistence.deleteLocalLinuxMount(id: saved.id) }
        let bridge = MountBridgeStub()
        let manager = makeManager(root: root, bridge: bridge)

        for id in [saved.id, UUID()] {
            await #expect(throws: LocalLinuxRuntimeError.self) {
                _ = try await manager.acquireLeases(ids: [id])
            }
        }
        #expect(await bridge.addedIDs.isEmpty)
        #expect(Persistence.loadLocalLinuxMounts().first { $0.id == saved.id }?.isEnabled == false)
    }

    @Test("忙碌或失效的原生租约不能被自动重新挂载掩盖", arguments: [Int32(-16), -116])
    func nonMissingLeaseFailureDoesNotRemount(code: Int32) async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try saveRecord(directory: root, access: .readOnly)
        defer { _ = Persistence.deleteLocalLinuxMount(id: saved.id) }
        let bridge = MountBridgeStub(leaseError: code)
        let manager = makeManager(root: root, bridge: bridge)

        await #expect(throws: LocalLinuxRuntimeError.self) {
            _ = try await manager.acquireLeases(ids: [saved.id])
        }
        #expect(await bridge.addedIDs.isEmpty)
        #expect(await bridge.leaseAttempts == [saved.id])
    }

    @Test("可解析的旧书签自动刷新，新的管理器可继续访问")
    func staleBookmarkRefreshesWithoutReauthorization() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try saveRecord(directory: root, access: .readOnly)
        defer { _ = Persistence.deleteLocalLinuxMount(id: saved.id) }
        let relocated = root.appendingPathComponent("移动后的目录", isDirectory: true)
        try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: true)
        try Data("原目录内容".utf8).write(to: relocated.appendingPathComponent("note.txt"))
        let manager = LocalLinuxMountManager(
            storage: LocalLinuxStorageManager(fileManager: NoCloudFileManager(), documentsDirectory: root, appGroupLayout: nil),
            bridge: MountBridgeStub(),
            resolveBookmark: { _ in (relocated, true) }
        )

        let access = try await manager.accessExternalDirectory(id: saved.id)
        #expect(access.url == relocated)
        let updated = try #require(Persistence.loadLocalLinuxMounts().first { $0.id == saved.id })
        #expect(updated.bookmark != saved.bookmark)
        #expect(updated.guestPath == saved.guestPath)
        #expect(updated.access == saved.access)
        #expect(updated.authorizationState == .available)

        let restored = try await makeManager(root: root, bridge: MountBridgeStub()).accessExternalDirectory(id: saved.id)
        #expect(try String(contentsOf: restored.url.appendingPathComponent("note.txt"), encoding: .utf8) == "原目录内容")
    }

    @Test("启用挂载不会覆盖准备过程中刷新的书签")
    func enablingKeepsRefreshedBookmark() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try saveRecord(directory: root, access: .readOnly, enabled: false)
        defer { _ = Persistence.deleteLocalLinuxMount(id: saved.id) }
        let relocated = root.appendingPathComponent("新位置", isDirectory: true)
        try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: true)
        let manager = LocalLinuxMountManager(
            storage: LocalLinuxStorageManager(fileManager: NoCloudFileManager(), documentsDirectory: root, appGroupLayout: nil),
            bridge: MountBridgeStub(),
            resolveBookmark: { _ in (relocated, true) }
        )

        let updated = try await manager.setEnabled(true, id: saved.id)

        #expect(updated.isEnabled)
        #expect(updated.bookmark != saved.bookmark)
        let bookmark = try #require(updated.bookmark)
        let resolved = try LocalLinuxExternalDirectory.resolveBookmark(bookmark)
        #expect(resolved.url.resolvingSymlinksInPath() == relocated.resolvingSymlinksInPath())
    }

    @Test("迟到的书签刷新保留新授权和配置且不会复活删除记录")
    func bookmarkRefreshDoesNotOverwriteNewConfiguration() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try saveRecord(directory: root, access: .readOnly)
        defer { _ = Persistence.deleteLocalLinuxMount(id: saved.id) }
        let originalBookmark = try #require(saved.bookmark)
        var updated = saved
        updated.bookmark = Data("重新授权的书签".utf8)
        updated.displayName = "新配置"
        updated.access = .readWrite
        updated.isEnabled = false
        #expect(Persistence.saveLocalLinuxMount(updated))
        #expect(Persistence.updateLocalLinuxMountLeaseCount(id: saved.id, delta: 2))
        let baseline = try #require(Persistence.loadLocalLinuxMounts().first { $0.id == saved.id })

        #expect(Persistence.refreshLocalLinuxMountBookmark(id: saved.id, replacing: originalBookmark, with: Data([1])))
        #expect(Persistence.loadLocalLinuxMounts().first { $0.id == saved.id } == baseline)
        let refreshed = Data("更新后的书签".utf8)
        let currentBookmark = try #require(baseline.bookmark)
        #expect(Persistence.refreshLocalLinuxMountBookmark(id: saved.id, replacing: currentBookmark, with: refreshed))
        var expected = baseline
        expected.bookmark = refreshed
        #expect(Persistence.loadLocalLinuxMounts().first { $0.id == saved.id } == expected)

        #expect(Persistence.deleteLocalLinuxMount(id: saved.id))
        #expect(Persistence.refreshLocalLinuxMountBookmark(id: saved.id, replacing: refreshed, with: Data([2])))
        #expect(!Persistence.loadLocalLinuxMounts().contains { $0.id == saved.id })
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
    private let leaseError: Int32?
    private var activeMounts: [UUID: LocalLinuxBridgeMount] = [:]
    private(set) var addedIDs: [UUID] = []
    private(set) var leaseAttempts: [UUID] = []
    private var removal: CheckedContinuation<Void, Never>?
    private var removalWaiter: CheckedContinuation<Void, Never>?

    init(addError: Int32? = nil, removeError: Int32? = nil, incrementLeaseOnAdd: Bool = false, pauseRemoval: Bool = false, leaseError: Int32? = nil) {
        self.addError = addError
        self.removeError = removeError
        self.incrementLeaseOnAdd = incrementLeaseOnAdd
        self.pauseRemoval = pauseRemoval
        self.leaseError = leaseError
    }

    func runtimePhase() -> Int32 { 2 }
    func mounts() -> [LocalLinuxBridgeMountInfo] {
        activeMounts.values.map {
            LocalLinuxBridgeMountInfo(id: $0.id, access: $0.access, state: 2, activeLeases: 0, activeReferences: 0, guestDirectory: $0.guestDirectory)
        }
    }
    func allowAddition() { addError = nil }

    func addMount(_ mount: LocalLinuxBridgeMount) throws {
        if let addError { throw LocalLinuxRuntimeError.bridgeFailure(operation: "添加测试挂载", linuxError: addError) }
        addedIDs.append(mount.id)
        activeMounts[mount.id] = mount
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
        activeMounts[id] = nil
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
        leaseAttempts.append(id)
        if let leaseError { throw LocalLinuxRuntimeError.bridgeFailure(operation: "取得测试挂载租约", linuxError: leaseError) }
        guard activeMounts[id] != nil else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "取得测试挂载租约", linuxError: -2)
        }
        return iSHAppleBridgeMountLease(native: nil, mountID: id)
    }
}
