// ============================================================================
// iSHAppleBridgeGuestFileSystem.swift
// ============================================================================
// ETOS LLM Studio
//
// Linux 文件工具只走 guest API，确保 fakefs inode、符号链接与只读 mount
// 权限保持真实；这里绝不把 RootFS/data 当普通宿主目录改写。
// ============================================================================

import Foundation

private final class LocalLinuxGuestFileInfoCollector {
    var values: [LocalLinuxGuestFileInfo] = []
}

private func localLinuxGuestFileInfoCallback(
    context: UnsafeMutableRawPointer?,
    name: UnsafePointer<CChar>?,
    device: UInt64,
    inode: UInt64,
    size: UInt64,
    blocks: UInt64,
    mode: UInt32,
    linkCount: UInt32,
    userID: UInt32,
    groupID: UInt32,
    blockSize: UInt32,
    accessSeconds: Int64,
    modificationSeconds: Int64,
    statusChangeSeconds: Int64,
    accessNanoseconds: UInt32,
    modificationNanoseconds: UInt32,
    statusChangeNanoseconds: UInt32
) {
    guard let context else { return }
    let collector = Unmanaged<LocalLinuxGuestFileInfoCollector>.fromOpaque(context).takeUnretainedValue()
    collector.values.append(
        LocalLinuxGuestFileInfo(
            name: name.map(String.init(cString:)),
            device: device,
            inode: inode,
            size: size,
            blocks: blocks,
            mode: mode,
            linkCount: linkCount,
            userID: userID,
            groupID: groupID,
            blockSize: blockSize,
            accessTime: localLinuxDate(seconds: accessSeconds, nanoseconds: accessNanoseconds),
            modificationTime: localLinuxDate(seconds: modificationSeconds, nanoseconds: modificationNanoseconds),
            statusChangeTime: localLinuxDate(seconds: statusChangeSeconds, nanoseconds: statusChangeNanoseconds)
        )
    )
}

private func localLinuxDate(seconds: Int64, nanoseconds: UInt32) -> Date {
    Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
}

public extension iSHAppleBridgeAdapter {
    func statGuestFile(path: String, requestID: UInt64, noFollow: Bool = false) throws -> LocalLinuxGuestFileInfo {
        try validateGuestFileRequest(path: path, requestID: requestID)
        let collector = LocalLinuxGuestFileInfoCollector()
        let status = try withETOSCString(path) { path in
            etosISHGuestFileStat(
                requestID,
                path,
                noFollow ? 1 : 0,
                Unmanaged.passUnretained(collector).toOpaque(),
                localLinuxGuestFileInfoCallback
            )
        }
        try requireSuccess(status, operation: "读取 Linux 文件属性")
        guard let value = collector.values.first else {
            throw LocalLinuxRuntimeError.bridgeFailure(operation: "读取 Linux 文件属性", linuxError: -1)
        }
        return value
    }

    func listGuestDirectory(
        path: String,
        requestID: UInt64,
        cursor: UInt64 = 0,
        maximumEntryCount: UInt32 = 128,
        noFollow: Bool = false
    ) throws -> LocalLinuxGuestDirectoryPage {
        try validateGuestFileRequest(path: path, requestID: requestID)
        guard maximumEntryCount != 0 else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Linux 目录页大小必须大于零。", comment: "Linux directory page validation error")
            )
        }
        let collector = LocalLinuxGuestFileInfoCollector()
        var nextCursor: UInt64 = 0
        var eof: Int32 = 0
        let status = try withETOSCString(path) { path in
            etosISHGuestFileList(
                requestID,
                path,
                noFollow ? 1 : 0,
                cursor,
                maximumEntryCount,
                Unmanaged.passUnretained(collector).toOpaque(),
                localLinuxGuestFileInfoCallback,
                &nextCursor,
                &eof
            )
        }
        try requireSuccess(status, operation: "列出 Linux 目录")
        return LocalLinuxGuestDirectoryPage(
            entries: collector.values,
            nextCursor: nextCursor,
            isComplete: eof != 0
        )
    }

    func readGuestFile(
        path: String,
        requestID: UInt64,
        offset: UInt64,
        maximumByteCount: UInt32,
        noFollow: Bool = false
    ) throws -> LocalLinuxGuestFileReadResult {
        try validateGuestFileRequest(path: path, requestID: requestID)
        guard maximumByteCount != 0 else {
            return LocalLinuxGuestFileReadResult(data: Data(), totalSize: 0, isComplete: false)
        }
        var buffer = Data(count: Int(maximumByteCount))
        var count: UInt32 = 0
        var totalSize: UInt64 = 0
        var eof: Int32 = 0
        let status = try withETOSCString(path) { path in
            buffer.withUnsafeMutableBytes { bytes in
                etosISHGuestFileRead(
                    requestID,
                    path,
                    noFollow ? 1 : 0,
                    offset,
                    bytes.baseAddress,
                    maximumByteCount,
                    &count,
                    &totalSize,
                    &eof
                )
            }
        }
        try requireSuccess(status, operation: "读取 Linux 文件")
        buffer.count = Int(count)
        return LocalLinuxGuestFileReadResult(data: buffer, totalSize: totalSize, isComplete: eof != 0)
    }

    func writeGuestFile(
        path: String,
        requestID: UInt64,
        data: Data,
        mode: UInt32 = 0o644,
        noFollow: Bool = false
    ) throws {
        try validateGuestFileRequest(path: path, requestID: requestID)
        guard data.count <= Int(UInt32.max) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("单次 Linux 文件写入过大。", comment: "Linux file write size error")
            )
        }
        let status = try withETOSCString(path) { path in
            data.withUnsafeBytes { bytes in
                etosISHGuestFileWrite(
                    requestID,
                    path,
                    noFollow ? 1 : 0,
                    bytes.baseAddress,
                    UInt32(bytes.count),
                    mode
                )
            }
        }
        try requireSuccess(status, operation: "写入 Linux 文件")
    }

    func editGuestFile(
        path: String,
        requestID: UInt64,
        offset: UInt64,
        removedLength: UInt64,
        replacement: Data,
        noFollow: Bool = false
    ) throws {
        try validateGuestFileRequest(path: path, requestID: requestID)
        guard replacement.count <= Int(UInt32.max) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("单次 Linux 文件编辑内容过大。", comment: "Linux file edit size error")
            )
        }
        let status = try withETOSCString(path) { path in
            replacement.withUnsafeBytes { bytes in
                etosISHGuestFileEdit(
                    requestID,
                    path,
                    noFollow ? 1 : 0,
                    offset,
                    removedLength,
                    bytes.baseAddress,
                    UInt32(bytes.count)
                )
            }
        }
        try requireSuccess(status, operation: "编辑 Linux 文件")
    }

    func removeGuestFile(
        path: String,
        requestID: UInt64,
        recursive: Bool,
        noFollow: Bool = false
    ) throws {
        try validateGuestFileRequest(path: path, requestID: requestID)
        let status = try withETOSCString(path) { path in
            etosISHGuestFileRemove(requestID, path, noFollow ? 1 : 0, recursive ? 1 : 0)
        }
        try requireSuccess(status, operation: "删除 Linux 文件")
    }

    func renameGuestFile(
        path: String,
        destination: String,
        requestID: UInt64,
        noFollow: Bool = false
    ) throws {
        try validateGuestFileRequest(path: path, requestID: requestID)
        guard destination.hasPrefix("/") else { throw LocalLinuxRuntimeError.invalidPath(destination) }
        let status = try withETOSCString(path) { path in
            try withETOSCString(destination) { destination in
                etosISHGuestFileRename(requestID, path, noFollow ? 1 : 0, destination)
            }
        }
        try requireSuccess(status, operation: "移动 Linux 文件")
    }

    func createGuestDirectory(
        path: String,
        requestID: UInt64,
        mode: UInt32 = 0o755,
        createParents: Bool = true,
        noFollow: Bool = false
    ) throws {
        try validateGuestFileRequest(path: path, requestID: requestID)
        let status = try withETOSCString(path) { path in
            etosISHGuestFileMkdir(requestID, path, noFollow ? 1 : 0, mode, createParents ? 1 : 0)
        }
        try requireSuccess(status, operation: "创建 Linux 目录")
    }

    private func validateGuestFileRequest(path: String, requestID: UInt64) throws {
        try requireAvailability()
        guard requestID != 0 else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Linux 文件请求缺少有效 ID。", comment: "Linux file request ID error")
            )
        }
        guard path.hasPrefix("/") else { throw LocalLinuxRuntimeError.invalidPath(path) }
    }
}
