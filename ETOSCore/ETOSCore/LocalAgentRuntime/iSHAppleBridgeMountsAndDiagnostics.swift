// ============================================================================
// iSHAppleBridgeMountsAndDiagnostics.swift
// ============================================================================
// ETOS LLM Studio
// ============================================================================

import Foundation

public final class iSHAppleBridgeMountLease: @unchecked Sendable {
    private let native: UnsafeMutableRawPointer
    public let mountID: UUID

    fileprivate init(native: UnsafeMutableRawPointer, mountID: UUID) {
        self.native = native
        self.mountID = mountID
    }

    deinit {
        etosISHMountLeaseRelease(native)
    }
}

private final class LocalLinuxMountInfoCollector {
    var values: [LocalLinuxBridgeMountInfo] = []
}

private func localLinuxMountInfoCallback(
    context: UnsafeMutableRawPointer?,
    idHigh: UInt64,
    idLow: UInt64,
    rawAccess: Int32,
    state: Int32,
    activeLeases: UInt64,
    activeReferences: UInt64,
    guestDirectory: UnsafePointer<CChar>?
) {
    guard let context,
          let access = LocalLinuxMountAccess(bridgeRawValue: rawAccess),
          let guestDirectory else { return }
    let collector = Unmanaged<LocalLinuxMountInfoCollector>.fromOpaque(context).takeUnretainedValue()
    collector.values.append(
        LocalLinuxBridgeMountInfo(
            id: LocalLinuxBridgeUUIDParts(high: idHigh, low: idLow).uuid,
            access: access,
            state: state,
            activeLeases: activeLeases,
            activeReferences: activeReferences,
            guestDirectory: String(cString: guestDirectory)
        )
    )
}

private final class LocalLinuxDiagnosticCollector {
    var values: [LocalLinuxBridgeDiagnosticEvent] = []
}

private func localLinuxDiagnosticCallback(
    context: UnsafeMutableRawPointer?,
    category: UInt32,
    kind: UInt32,
    scope: UInt32,
    architecture: UInt32,
    backend: UInt32,
    linuxError: Int32,
    signal: Int32,
    opcode: UInt32,
    sequence: UInt64,
    requestID: UInt64,
    guestProgramCounter: UInt64,
    systemCallNumber: UInt64,
    guestProcessID: UInt32,
    guestThreadGroupID: UInt32,
    processName: UnsafePointer<CChar>?,
    systemCallName: UnsafePointer<CChar>?,
    buildIdentity: UnsafePointer<CChar>?
) {
    guard let context else { return }
    let collector = Unmanaged<LocalLinuxDiagnosticCollector>.fromOpaque(context).takeUnretainedValue()
    let syscall = systemCallName.map(String.init(cString:)).flatMap { $0.isEmpty ? nil : $0 }
    collector.values.append(
        LocalLinuxBridgeDiagnosticEvent(
            category: category,
            kind: kind,
            scope: scope,
            architecture: architecture,
            backend: backend,
            linuxError: linuxError,
            signal: signal,
            opcode: opcode,
            sequence: sequence,
            requestID: requestID,
            guestProgramCounter: guestProgramCounter,
            systemCallNumber: systemCallNumber,
            guestProcessID: guestProcessID,
            guestThreadGroupID: guestThreadGroupID,
            processName: processName.map(String.init(cString:)).flatMap { $0.isEmpty ? nil : $0 },
            systemCallName: syscall,
            buildIdentity: buildIdentity.map(String.init(cString:)) ?? ""
        )
    )
}

public extension iSHAppleBridgeAdapter {
    func addMount(_ mount: LocalLinuxBridgeMount) throws {
        try requireAvailability()
        let id = LocalLinuxBridgeUUIDParts(mount.id)
        let status = try withETOSCString(mount.guestDirectory) { guestDirectory in
            etosISHMountAdd(
                id.high,
                id.low,
                mount.access.bridgeRawValue,
                mount.hostDirectoryDescriptor,
                guestDirectory
            )
        }
        try requireSuccess(status, operation: "添加 Linux 挂载")
    }

    func removeMount(id: UUID, force: Bool) throws {
        try requireAvailability()
        let id = LocalLinuxBridgeUUIDParts(id)
        try requireSuccess(
            etosISHMountRemove(id.high, id.low, force ? 1 : 0),
            operation: "移除 Linux 挂载"
        )
    }

    func mounts() throws -> [LocalLinuxBridgeMountInfo] {
        try requireAvailability()
        let collector = LocalLinuxMountInfoCollector()
        let status = etosISHMountList(
            Unmanaged.passUnretained(collector).toOpaque(),
            localLinuxMountInfoCallback
        )
        try requireSuccess(status, operation: "列出 Linux 挂载")
        return collector.values
    }

    func acquireMountLease(id: UUID) throws -> iSHAppleBridgeMountLease {
        try requireAvailability()
        let parts = LocalLinuxBridgeUUIDParts(id)
        var native: UnsafeMutableRawPointer?
        let status = etosISHMountLeaseAcquire(parts.high, parts.low, &native)
        try requireSuccess(status, operation: "取得 Linux 挂载租约")
        guard let native else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "取得 Linux 挂载租约", linuxError: -1)
        }
        return iSHAppleBridgeMountLease(native: native, mountID: id)
    }

    func drainDiagnostics(
        scope: UInt32,
        requestID: UInt64,
        maximumCount: UInt32 = 128
    ) throws -> [LocalLinuxBridgeDiagnosticEvent] {
        try requireAvailability()
        guard maximumCount != 0 else { return [] }
        let collector = LocalLinuxDiagnosticCollector()
        var drained: UInt32 = 0
        let status = etosISHDiagnosticsDrain(
            scope,
            requestID,
            maximumCount,
            Unmanaged.passUnretained(collector).toOpaque(),
            localLinuxDiagnosticCallback,
            &drained
        )
        try requireSuccess(status, operation: "读取 Linux 兼容性诊断")
        return collector.values
    }

    @discardableResult
    func clearDiagnostics(scope: UInt32, requestID: UInt64) throws -> UInt32 {
        try requireAvailability()
        var cleared: UInt32 = 0
        try requireSuccess(
            etosISHDiagnosticsClear(scope, requestID, &cleared),
            operation: "清除 Linux 兼容性诊断"
        )
        return cleared
    }
}
