// ============================================================================
// LocalLinuxMountManager.swift
// ============================================================================
// ETOS LLM Studio
//
// 宿主路径仅在这里解析。桥接层只接收已打开的目录 fd；security scope 在
// mount 存续期间保持，guest 与诊断始终只看到稳定 UUID 和 /mnt 路径。
// ============================================================================

import Darwin
import Foundation

public final class LocalLinuxPreparedMountSet: @unchecked Sendable {
    public let mounts: [LocalLinuxBridgeMount]
    private let descriptors: [Int32]

    init(mounts: [LocalLinuxBridgeMount], descriptors: [Int32]) {
        self.mounts = mounts
        self.descriptors = descriptors
    }

    deinit {
        descriptors.forEach { close($0) }
    }
}

public final class LocalLinuxMountLease: @unchecked Sendable {
    public let mountID: UUID
    private var bridgeLease: iSHAppleBridgeMountLease?
    private let releaseHandler: @Sendable (UUID) -> Void
    private let lock = NSLock()
    private var didRelease = false

    fileprivate init(
        bridgeLease: iSHAppleBridgeMountLease,
        releaseHandler: @escaping @Sendable (UUID) -> Void
    ) {
        mountID = bridgeLease.mountID
        self.bridgeLease = bridgeLease
        self.releaseHandler = releaseHandler
    }

    deinit {
        release()
    }

    public func release() {
        lock.lock()
        guard !didRelease else {
            lock.unlock()
            return
        }
        didRelease = true
        var lease = bridgeLease
        bridgeLease = nil
        lock.unlock()
        // native lease 必须先归还，随后才能安全尝试移除临时挂载。
        withExtendedLifetime(lease) {}
        lease = nil
        releaseHandler(mountID)
    }
}

public final class LocalLinuxDirectoryAccess: @unchecked Sendable {
    public let url: URL
    private let shouldStop: Bool

    fileprivate init(url: URL, shouldStop: Bool) {
        self.url = url
        self.shouldStop = shouldStop
    }

    deinit {
        if shouldStop { url.stopAccessingSecurityScopedResource() }
    }
}

public actor LocalLinuxMountManager {
    public static let shared = LocalLinuxMountManager()

    public static let homeMountID = UUID(uuidString: "4203E597-D916-424B-B584-1569682C9A4C")!
    public static let workspaceMountID = UUID(uuidString: "B0081364-EF17-4F76-9EA8-3FA3BEC990A2")!
    public static let sharedMountID = UUID(uuidString: "D76E20A8-628B-4C6A-AD29-7F3D7DF1DF1E")!
    public static let iCloudMountID = UUID(uuidString: "62046572-CAD6-4F86-BF4F-4B83C36A43BB")!
    public static let homeMountGuestPath = "/mnt/home"
    public static let workspaceMountGuestPath = "/mnt/workspaces"
    public static let sharedMountGuestPath = "/mnt/shared"
    public static let iCloudGuestPath = "/mnt/icloud"
    public static let appMountsDirectoryName = "ETOSMounts"
    public static let appMountsDisplayPath = "Documents/ETOSMounts"

    public static func appMountDisplayPath(id: UUID) -> String {
        "\(appMountsDisplayPath)/\(id.uuidString.lowercased())"
    }

    public static func appMountURI(id: UUID) -> String {
        "app://\(appMountsDirectoryName)/\(id.uuidString.lowercased())"
    }

    private let storage: LocalLinuxStorageManager
    private let bridge: iSHAppleBridgeAdapter
    private var scopedResources: [UUID: LocalLinuxDirectoryAccess] = [:]
    private struct TransientSkillMount {
        let id: UUID
        let canonicalHostPath: String
        var leaseCount: Int
    }
    private var transientSkillMounts: [String: TransientSkillMount] = [:]

    public init(
        storage: LocalLinuxStorageManager = .shared,
        bridge: iSHAppleBridgeAdapter = .shared
    ) {
        self.storage = storage
        self.bridge = bridge
    }

    public func records() -> [LocalLinuxMountRecord] {
        Persistence.loadLocalLinuxMounts()
    }

    /// 文件授权可用不代表已经挂入当前内核；数据库恢复和宿主文件浏览都会改变前者。
    public func activeExternalMountIDs() async throws -> [UUID] {
        let activeIDs = Set(try await bridge.mounts().filter { $0.state == 2 }.map(\.id))
        return records().filter { $0.isEnabled && activeIDs.contains($0.id) }.map(\.id)
    }

    /// 为宿主界面保留一次安全作用域访问，调用方应在文件浏览界面存续期间持有返回值。
    public func accessExternalDirectory(id: UUID) throws -> LocalLinuxDirectoryAccess {
        guard let record = records().first(where: { $0.id == id }) else {
            throw LocalLinuxRuntimeError.invalidPath(id.uuidString)
        }
        let resource = try prepareExternalDirectory(record)
        persistAuthorizationState(record, state: .available)
        return resource
    }

    public func addExternalDirectory(
        _ url: URL,
        displayName: String,
        access: LocalLinuxMountAccess
    ) async throws -> LocalLinuxMountRecord {
        let bookmark = try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: [.isDirectoryKey, .isUbiquitousItemKey],
            relativeTo: nil
        )
        let id = UUID()
        let record = LocalLinuxMountRecord(
            id: id,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? url.lastPathComponent
                : displayName,
            bookmark: bookmark,
            access: access,
            guestPath: "/mnt/etos/\(id.uuidString.lowercased())"
        )
        guard Persistence.saveLocalLinuxMount(record) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存 Linux 挂载。", comment: "Save Linux mount failure")
            )
        }
        if await bridge.runtimePhase() == 2 {
            do {
                try await mountNow(id: id)
            } catch {
                throw error
            }
        }
        return record
    }

    public func update(_ record: LocalLinuxMountRecord) throws {
        guard Persistence.saveLocalLinuxMount(record) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法更新 Linux 挂载。", comment: "Update Linux mount failure")
            )
        }
    }

    public func reauthorize(
        id: UUID,
        with url: URL,
        access: LocalLinuxMountAccess
    ) async throws -> LocalLinuxMountRecord {
        guard var record = records().first(where: { $0.id == id }) else {
            throw LocalLinuxRuntimeError.invalidPath(id.uuidString)
        }
        let wasMounted = scopedResources[id] != nil
        record.bookmark = try url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: [.isDirectoryKey, .isUbiquitousItemKey],
            relativeTo: nil
        )
        record.displayName = url.lastPathComponent
        record.access = access
        record.authorizationState = .available
        record.updatedAt = Date()

        if await bridge.runtimePhase() == 2, record.isEnabled {
            do {
                let prepared = try prepareExternalMount(record)
                defer { close(prepared.descriptor) }
                if wasMounted {
                    try await bridge.removeMount(id: id, force: false)
                }
                try await bridge.addMount(prepared.mount)
                scopedResources[id] = prepared.resource
            } catch {
                if records().first(where: { $0.id == id })?.authorizationState == .materializing {
                    persistAuthorizationState(record, state: .unavailable)
                }
                throw error
            }
        }
        guard Persistence.saveLocalLinuxMount(record) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存重新授权的 Linux 挂载。", comment: "Save reauthorized Linux mount failure")
            )
        }
        return record
    }

    public func setEnabled(_ isEnabled: Bool, id: UUID) async throws -> LocalLinuxMountRecord {
        guard var record = records().first(where: { $0.id == id }) else {
            throw LocalLinuxRuntimeError.invalidPath(id.uuidString)
        }
        guard record.isEnabled != isEnabled else { return record }
        if await bridge.runtimePhase() == 2 {
            if isEnabled {
                do {
                    let prepared = try prepareExternalMount(record)
                    defer { close(prepared.descriptor) }
                    try await bridge.addMount(prepared.mount)
                    scopedResources[id] = prepared.resource
                    record.authorizationState = .available
                } catch {
                    if records().first(where: { $0.id == id })?.authorizationState == .materializing {
                        persistAuthorizationState(record, state: .unavailable)
                    }
                    throw error
                }
            } else {
                try await bridge.removeMount(id: id, force: false)
                scopedResources[id] = nil
            }
        }
        record.isEnabled = isEnabled
        record.updatedAt = Date()
        guard Persistence.saveLocalLinuxMount(record) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法更新 Linux 挂载状态。", comment: "Update Linux mount enabled state failure")
            )
        }
        return record
    }

    public func delete(id: UUID, force: Bool) async throws {
        if force {
            await LocalLinuxJobScheduler.shared.cancelJobs(usingMountID: id)
        }
        if await bridge.runtimePhase() == 2 {
            try await bridge.removeMount(id: id, force: force)
        }
        scopedResources[id] = nil
        guard Persistence.deleteLocalLinuxMount(id: id) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法删除 Linux 挂载。", comment: "Delete Linux mount failure")
            )
        }
    }

    public func prepareStartupMounts() async throws -> LocalLinuxPreparedMountSet {
        let layout = try await storage.prepareLayout()
        var mounts: [LocalLinuxBridgeMount] = []
        var descriptors: [Int32] = []
        var didFinish = false
        defer {
            if !didFinish { descriptors.forEach { close($0) } }
        }

        try appendInternalMount(
            id: Self.homeMountID,
            url: layout.home,
            guestDirectory: Self.homeMountGuestPath,
            mounts: &mounts,
            descriptors: &descriptors
        )
        try appendInternalMount(
            id: Self.workspaceMountID,
            url: layout.workspaces,
            guestDirectory: Self.workspaceMountGuestPath,
            mounts: &mounts,
            descriptors: &descriptors
        )
        // Shared 由 runtime 的 sharedDirectory 参数保留挂到 /mnt/shared；
        // 动态 mount registry 会拒绝再次占用该路径。
        if let iCloudURL = try await storage.iCloudLinuxDirectory() {
            try appendInternalMount(
                id: Self.iCloudMountID,
                url: iCloudURL,
                guestDirectory: Self.iCloudGuestPath,
                mounts: &mounts,
                descriptors: &descriptors
            )
        }

        for record in records() where record.isEnabled {
            do {
                let prepared = try prepareExternalMount(record)
                mounts.append(prepared.mount)
                descriptors.append(prepared.descriptor)
                scopedResources[record.id] = prepared.resource
                if record.authorizationState != .available {
                    var updated = record
                    updated.authorizationState = .available
                    updated.updatedAt = Date()
                    _ = Persistence.saveLocalLinuxMount(updated)
                }
            } catch {
                // prepareExternalMount 已区分书签失效、物化失败等状态。
            }
        }
        didFinish = true
        return LocalLinuxPreparedMountSet(mounts: mounts, descriptors: descriptors)
    }

    public func mountNow(id: UUID) async throws {
        guard let record = records().first(where: { $0.id == id }) else {
            throw LocalLinuxRuntimeError.invalidPath(id.uuidString)
        }
        do {
            let prepared = try prepareExternalMount(record)
            defer { close(prepared.descriptor) }
            try await bridge.addMount(prepared.mount)
            scopedResources[id] = prepared.resource
        } catch {
            if records().first(where: { $0.id == id })?.authorizationState == .materializing {
                persistAuthorizationState(record, state: .unavailable)
            }
            throw error
        }
        var updated = record
        updated.authorizationState = .available
        updated.updatedAt = Date()
        _ = Persistence.saveLocalLinuxMount(updated)
    }

    public func acquireLeases(ids: [UUID]) async throws -> [LocalLinuxMountLease] {
        var leases: [LocalLinuxMountLease] = []
        do {
            for id in ids {
                let bridgeLease = try await bridge.acquireMountLease(id: id)
                incrementPersistedLeaseCount(id: id)
                leases.append(
                    LocalLinuxMountLease(bridgeLease: bridgeLease) { [weak self] releasedID in
                        Task { await self?.decrementPersistedLeaseCount(id: releasedID) }
                    }
                )
            }
            return leases
        } catch {
            leases.removeAll()
            throw error
        }
    }

    /// Skill 包只在持有租约的执行或 Agent Run 存续期间挂载，且 guest 永远只能只读访问。
    public func acquireReadOnlySkillMount(
        skillID: String,
        hostDirectory: URL,
        guestDirectory: String? = nil
    ) async throws -> LocalLinuxMountLease {
        guard SkillPaths.isValidSkillName(skillID) else {
            throw SkillExecutionError.invalidScriptPath
        }
        let canonicalDirectory = hostDirectory.resolvingSymlinksInPath().standardizedFileURL
        let skillGuestRoot = "/mnt/etos/skills/\(skillID)"
        let guestPath = guestDirectory ?? skillGuestRoot
        if guestPath != skillGuestRoot {
            let prefix = skillGuestRoot + "/"
            guard guestPath.hasPrefix(prefix) else {
                throw SkillExecutionError.invalidScriptPath
            }
            let suffix = String(guestPath.dropFirst(prefix.count))
            guard !suffix.isEmpty,
                  suffix.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                      !$0.isEmpty && $0 != "." && $0 != ".."
                  }) else {
                throw SkillExecutionError.invalidScriptPath
            }
        }
        if var existing = transientSkillMounts[guestPath] {
            guard existing.canonicalHostPath == canonicalDirectory.path else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("同名 Skill 的只读挂载指向不同目录。", comment: "Conflicting transient Skill mount")
                )
            }
            let bridgeLease = try await bridge.acquireMountLease(id: existing.id)
            existing.leaseCount += 1
            transientSkillMounts[guestPath] = existing
            return LocalLinuxMountLease(bridgeLease: bridgeLease) { [weak self] releasedID in
                Task { await self?.releaseTransientSkillMount(guestPath: guestPath, mountID: releasedID) }
            }
        }

        let descriptor = canonicalDirectory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法打开 Skill 目录用于只读挂载。", comment: "Open Skill directory for read-only mount failure")
            )
        }
        defer { close(descriptor) }

        let id = UUID()
        do {
            try await bridge.addMount(
                LocalLinuxBridgeMount(
                    id: id,
                    hostDirectoryDescriptor: descriptor,
                    guestDirectory: guestPath,
                    access: .readOnly
                )
            )
            let bridgeLease = try await bridge.acquireMountLease(id: id)
            transientSkillMounts[guestPath] = TransientSkillMount(
                id: id,
                canonicalHostPath: canonicalDirectory.path,
                leaseCount: 1
            )
            return LocalLinuxMountLease(bridgeLease: bridgeLease) { [weak self] releasedID in
                Task { await self?.releaseTransientSkillMount(guestPath: guestPath, mountID: releasedID) }
            }
        } catch {
            try? await bridge.removeMount(id: id, force: false)
            throw error
        }
    }

    public func releaseAuthorization(id: UUID) {
        scopedResources[id] = nil
    }

    public func releaseAllAuthorizations() {
        scopedResources.removeAll()
    }

    public func runtimeDidStop() {
        scopedResources.removeAll()
        transientSkillMounts.removeAll()
        resetStaleLeaseCountsAfterLaunch()
    }

    public func resetStaleLeaseCountsAfterLaunch() {
        _ = Persistence.resetLocalLinuxMountLeaseCounts()
    }

    private func incrementPersistedLeaseCount(id: UUID) {
        _ = Persistence.updateLocalLinuxMountLeaseCount(id: id, delta: 1)
    }

    private func decrementPersistedLeaseCount(id: UUID) {
        _ = Persistence.updateLocalLinuxMountLeaseCount(id: id, delta: -1)
    }

    private func releaseTransientSkillMount(guestPath: String, mountID: UUID) async {
        // 重启前排队的释放回调不能减少新内核中同一路径的租约。
        guard var mount = transientSkillMounts[guestPath], mount.id == mountID else { return }
        mount.leaseCount -= 1
        if mount.leaseCount > 0 {
            transientSkillMounts[guestPath] = mount
            return
        }
        do {
            try await bridge.removeMount(id: mount.id, force: false)
            transientSkillMounts[guestPath] = nil
        } catch {
            // 仍有 bridge 引用时保留记录；下一次释放或取得时不会覆盖同一路径。
            mount.leaseCount = 0
            transientSkillMounts[guestPath] = mount
        }
    }

    private func appendInternalMount(
        id: UUID,
        url: URL,
        guestDirectory: String,
        mounts: inout [LocalLinuxBridgeMount],
        descriptors: inout [Int32]
    ) throws {
        let descriptor = openDirectory(url)
        guard descriptor >= 0 else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                String(
                    format: NSLocalizedString("无法打开 Linux 目录：%@", comment: "Open Linux host directory failure"),
                    url.lastPathComponent
                )
            )
        }
        descriptors.append(descriptor)
        mounts.append(
            LocalLinuxBridgeMount(
                id: id,
                hostDirectoryDescriptor: descriptor,
                guestDirectory: guestDirectory,
                access: .readWrite
            )
        )
    }

    private func prepareExternalMount(
        _ record: LocalLinuxMountRecord
    ) throws -> (mount: LocalLinuxBridgeMount, descriptor: Int32, resource: LocalLinuxDirectoryAccess) {
        // 恢复的记录属于外部输入，不能占用 runtime 保留的内部挂载路径或身份。
        guard record.guestPath == "/mnt/etos/\(record.id.uuidString.lowercased())",
              ![Self.homeMountID, Self.workspaceMountID, Self.sharedMountID, Self.iCloudMountID].contains(record.id) else {
            persistAuthorizationState(record, state: .unavailable)
            throw LocalLinuxRuntimeError.invalidPath(record.guestPath)
        }
        let resource = try prepareExternalDirectory(record)
        let descriptor = openDirectory(resource.url)
        guard descriptor >= 0 else {
            persistAuthorizationState(record, state: .unavailable)
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法打开已授权目录。", comment: "Open authorized Linux directory failure")
            )
        }
        return (
            LocalLinuxBridgeMount(
                id: record.id,
                hostDirectoryDescriptor: descriptor,
                guestDirectory: record.guestPath,
                access: record.access
            ),
            descriptor,
            resource
        )
    }

    private func prepareExternalDirectory(
        _ record: LocalLinuxMountRecord
    ) throws -> LocalLinuxDirectoryAccess {
        guard let bookmark = record.bookmark else {
            persistAuthorizationState(record, state: .needsReauthorization)
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("挂载缺少文件访问授权。", comment: "Linux mount bookmark missing error")
            )
        }
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            // 重装后的书签可能直接抛错，而不是返回 stale；同样不能沿用快照中的 available。
            persistAuthorizationState(record, state: .needsReauthorization)
            throw error
        }
        guard !stale else {
            persistAuthorizationState(record, state: .needsReauthorization)
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("挂载授权已失效，请重新选择目录。", comment: "Linux mount bookmark stale error")
            )
        }
        let shouldStop = url.startAccessingSecurityScopedResource()
        let resource = LocalLinuxDirectoryAccess(url: url, shouldStop: shouldStop)
        persistAuthorizationState(record, state: .materializing)
        do {
            try materializeDirectory(url)
        } catch {
            persistAuthorizationState(record, state: .unavailable)
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString(
                    "外部目录尚未在本机准备好。请先在“文件”App 中打开该目录，等待 iCloud 或文件提供者下载完成后重试。",
                    comment: "Linux mount File Provider materialization error"
                )
            )
        }
        return resource
    }

    private func materializeDirectory(_ url: URL) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        let initialValues = try url.resourceValues(forKeys: keys)
        if initialValues.isUbiquitousItem == true,
           initialValues.ubiquitousItemDownloadingStatus != .current {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        var coordinationError: NSError?
        var readError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let values = try coordinatedURL.resourceValues(forKeys: keys)
                guard values.isDirectory == true else {
                    throw LocalLinuxRuntimeError.invalidPath(coordinatedURL.path)
                }
                if values.isUbiquitousItem == true,
                   values.ubiquitousItemDownloadingStatus != .current {
                    throw LocalLinuxRuntimeError.runtimeUnavailable("file-provider-materializing")
                }
            } catch {
                readError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
    }

    private func persistAuthorizationState(
        _ record: LocalLinuxMountRecord,
        state: LocalLinuxMountAuthorizationState
    ) {
        var updated = record
        updated.authorizationState = state
        updated.updatedAt = Date()
        _ = Persistence.saveLocalLinuxMount(updated)
    }

    private func openDirectory(_ url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
    }
}
