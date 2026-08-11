// ============================================================================
// iSHAppleBridgeAdapter.swift
// ============================================================================
// ETOS LLM Studio
//
// 进程内 iSH runtime 的唯一 Swift 入口。调用方只传 ETOS 值类型，桥接边界
// 负责 C 字符串生命周期、固定宽度参数和 Linux errno。
// ============================================================================

import Foundation

public actor iSHAppleBridgeAdapter {
    public static let shared = iSHAppleBridgeAdapter()

    public nonisolated static var isAvailable: Bool {
        etosISHIsAvailable() != 0
    }

    public func installRootFSArchive(
        archiveURL: URL,
        metadata: LocalLinuxSeedMetadata,
        persistentParent: URL,
        rootName: String,
        onProgress: @escaping @Sendable (LocalLinuxInstallProgress) -> Bool
    ) throws -> LocalLinuxRootFSInstallDisposition {
        try requireAvailability()
        let bridge = LocalLinuxRootFSProgressBridge(onProgress: onProgress)
        var disposition: Int32 = -1
        let status = try withETOSCString(archiveURL.path) { archivePath in
            try withETOSCString(metadata.archiveSHA256.lowercased()) { expectedSHA256 in
                try withETOSCString(persistentParent.path) { parent in
                    try withETOSCString(rootName) { rootName in
                        etosISHRootFSInstallArchive(
                            archivePath,
                            expectedSHA256,
                            metadata.uncompressedBytes,
                            metadata.entryCount,
                            parent,
                            rootName,
                            Unmanaged.passUnretained(bridge).toOpaque(),
                            localLinuxRootFSProgressCallback,
                            &disposition
                        )
                    }
                }
            }
        }
        try requireSuccess(status, operation: "安装压缩 RootFS")
        switch disposition {
        case LocalLinuxBridgeConstants.rootFSInstalled: return .installed
        case LocalLinuxBridgeConstants.rootFSAlreadyPresent: return .alreadyPresent
        default:
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "读取 RootFS 安装结果", linuxError: disposition)
        }
    }

    public func startRuntime(
        rootData: URL,
        sharedDirectory: URL,
        socketPrefix: String,
        hostname: String,
        bootCommand: String,
        startupMounts: [LocalLinuxBridgeMount]
    ) throws {
        try requireAvailability()
        let ids = startupMounts.map { LocalLinuxBridgeUUIDParts($0.id) }
        let high = ids.map(\.high)
        let low = ids.map(\.low)
        let access = startupMounts.map { $0.access.bridgeRawValue }
        let descriptors = startupMounts.map(\.hostDirectoryDescriptor)
        let guestDirectories = startupMounts.map(\.guestDirectory)

        let status = try withETOSCString(rootData.path) { rootData in
            try withETOSCString(sharedDirectory.path) { sharedDirectory in
                try withETOSCString(socketPrefix) { socketPrefix in
                    try withETOSCString(hostname) { hostname in
                        try withETOSCString(bootCommand) { bootCommand in
                            try withETOSCStringVector(guestDirectories) { guestPointers, count in
                                high.withUnsafeBufferPointer { high in
                                    low.withUnsafeBufferPointer { low in
                                        access.withUnsafeBufferPointer { access in
                                            descriptors.withUnsafeBufferPointer { descriptors in
                                                etosISHRuntimeStart(
                                                    rootData,
                                                    sharedDirectory,
                                                    socketPrefix,
                                                    hostname,
                                                    bootCommand,
                                                    high.baseAddress,
                                                    low.baseAddress,
                                                    access.baseAddress,
                                                    descriptors.baseAddress,
                                                    guestPointers,
                                                    count
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        try requireSuccess(status, operation: "启动 Linux runtime")
    }

    public func stopRuntime() throws {
        try requireAvailability()
        try requireSuccess(etosISHRuntimeStop(), operation: "停止 Linux runtime")
    }

    public func runtimePhase() -> Int32 {
        etosISHRuntimePhase()
    }

    public func runtimeLastError() -> Int32 {
        etosISHRuntimeLastError()
    }

    public func runtimeCapabilities() throws -> LocalLinuxRuntimeCapabilities {
        try requireAvailability()
        var flags: UInt64 = 0
        var architecture: UInt32 = 0
        var backend: UInt32 = 0
        var abiVersion: UInt32 = 0
        let status = etosISHRuntimeCapabilities(&flags, &architecture, &backend, &abiVersion)
        try requireSuccess(status, operation: "读取 Linux runtime 能力")
        let backendName: String
        switch backend {
        case 1: backendName = "c"
        case 2: backendName = "threaded"
        default: backendName = "unknown"
        }
        return LocalLinuxRuntimeCapabilities(
            supportsPTY: flags & LocalLinuxBridgeConstants.capabilityPTY != 0,
            supportsLiveMounts: flags & LocalLinuxBridgeConstants.capabilityLiveMounts != 0,
            supportsDiagnostics: flags & LocalLinuxBridgeConstants.capabilityDiagnostics != 0,
            supportsGuestFiles: flags & LocalLinuxBridgeConstants.capabilityGuestFiles != 0,
            guestArchitecture: architecture == 1 ? "aarch64" : "unknown-\(architecture)",
            backend: backendName,
            publicABIVersion: abiVersion
        )
    }

    public func startCommand(
        requestID: UInt64,
        request: LocalLinuxJobRequest,
        onOutput: @escaping @Sendable (LocalLinuxOutputStream, Data, Int32) -> Void
    ) throws -> iSHAppleBridgeCommandSession {
        try requireAvailability()
        return try iSHAppleBridgeCommandSession.start(
            requestID: requestID,
            request: request,
            onOutput: onOutput
        )
    }

    public func startTerminal(
        request: LocalLinuxBridgeTerminalRequest,
        onOutput: @escaping @Sendable (Data, UInt64) -> Void
    ) throws -> iSHAppleBridgeTerminalSession {
        try requireAvailability()
        return try iSHAppleBridgeTerminalSession.start(request: request, onOutput: onOutput)
    }

    func requireAvailability() throws {
        guard Self.isAvailable else { throw LocalLinuxRuntimeError.unsupportedPlatform }
    }

    func requireSuccess(_ status: Int32, operation: String) throws {
        guard status == 0 else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: operation, linuxError: status)
        }
    }
}

private final class LocalLinuxRootFSProgressBridge: @unchecked Sendable {
    let onProgress: @Sendable (LocalLinuxInstallProgress) -> Bool

    init(onProgress: @escaping @Sendable (LocalLinuxInstallProgress) -> Bool) {
        self.onProgress = onProgress
    }
}

private func localLinuxRootFSProgressCallback(
    context: UnsafeMutableRawPointer?,
    rawPhase: UInt32,
    flags: UInt32,
    compressedCompleted: UInt64,
    compressedTotal: UInt64,
    extractedCompleted: UInt64,
    extractedTotal: UInt64,
    entriesCompleted: UInt64,
    entriesTotal: UInt64,
    currentPath: UnsafePointer<CChar>?
) -> Int32 {
    guard let context else { return 0 }
    let bridge = Unmanaged<LocalLinuxRootFSProgressBridge>.fromOpaque(context).takeUnretainedValue()
    let phase: LocalLinuxInstallPhase
    switch rawPhase {
    case 1: phase = .verifying
    case 2: phase = .extracting
    case 3: phase = .validating
    case 4: phase = .publishing
    case 5: phase = .completed
    default: phase = .checking
    }
    let progress = LocalLinuxInstallProgress(
        phase: phase,
        completedBytes: rawPhase == 1 ? compressedCompleted : extractedCompleted,
        totalBytes: rawPhase == 1 ? compressedTotal : extractedTotal,
        completedEntries: entriesCompleted,
        totalEntries: entriesTotal,
        currentPath: currentPath.map(String.init(cString:))
    )
    _ = flags
    return bridge.onProgress(progress) ? 0 : 1
}

func withETOSCString<Result>(
    _ value: String,
    _ body: (UnsafePointer<CChar>) throws -> Result
) throws -> Result {
    guard !value.utf8.contains(0) else {
        throw LocalLinuxRuntimeError.invalidPath(value)
    }
    return try value.withCString(body)
}

func withETOSOptionalCString<Result>(
    _ value: String?,
    _ body: (UnsafePointer<CChar>?) throws -> Result
) throws -> Result {
    guard let value else { return try body(nil) }
    return try withETOSCString(value) { try body($0) }
}

func withETOSCStringVector<Result>(
    _ values: [String],
    _ body: (UnsafePointer<UnsafePointer<CChar>?>?, UInt32) throws -> Result
) throws -> Result {
    guard values.count <= Int(UInt32.max) else {
        throw LocalLinuxRuntimeError.runtimeUnavailable(
            NSLocalizedString("Linux 参数数量超出桥接范围。", comment: "Linux bridge argument count error")
        )
    }
    guard values.allSatisfy({ !$0.utf8.contains(0) }) else {
        throw LocalLinuxRuntimeError.runtimeUnavailable(
            NSLocalizedString("Linux 参数包含无效的空字符。", comment: "Linux bridge NUL argument error")
        )
    }
    guard !values.isEmpty else { return try body(nil, 0) }

    let allocated = values.map { strdup($0) }
    guard allocated.allSatisfy({ $0 != nil }) else {
        allocated.forEach { free($0) }
        throw LocalLinuxRuntimeError.runtimeUnavailable(
            NSLocalizedString("无法准备 Linux 参数。", comment: "Linux bridge argument allocation error")
        )
    }
    defer { allocated.forEach { free($0) } }
    let pointers: [UnsafePointer<CChar>?] = allocated.map { pointer in
        pointer.map { UnsafePointer($0) }
    }
    return try pointers.withUnsafeBufferPointer { buffer in
        try body(buffer.baseAddress, UInt32(values.count))
    }
}
