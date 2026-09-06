// ============================================================================
// iSHAppleBridgeTypes.swift
// ============================================================================
// ETOS LLM Studio
//
// ETOS 自己持有的桥接值类型；任何 iSH 私有或 SDK 类型都不会穿过这一层。
// ============================================================================

import Foundation

public enum LocalLinuxRootFSInstallDisposition: Equatable, Sendable {
    case installed
    case alreadyPresent
}

public struct LocalLinuxBridgeMount: Equatable, Sendable {
    public let id: UUID
    public let hostDirectoryDescriptor: Int32
    public let guestDirectory: String
    public let access: LocalLinuxMountAccess

    public init(
        id: UUID,
        hostDirectoryDescriptor: Int32,
        guestDirectory: String,
        access: LocalLinuxMountAccess
    ) {
        self.id = id
        self.hostDirectoryDescriptor = hostDirectoryDescriptor
        self.guestDirectory = guestDirectory
        self.access = access
    }
}

public struct LocalLinuxBridgeMountInfo: Equatable, Sendable {
    public let id: UUID
    public let access: LocalLinuxMountAccess
    public let state: Int32
    public let activeLeases: UInt64
    public let activeReferences: UInt64
    public let guestDirectory: String
}

public struct LocalLinuxBridgeCommandResult: Equatable, Sendable {
    public let requestID: UInt64
    public let completionReason: LocalLinuxCompletionReason
    public let exitCode: Int32
    public let terminationSignal: Int32
    public let linuxError: Int32
    public let stdoutBytes: UInt64
    public let stderrBytes: UInt64
    public let elapsedMilliseconds: UInt64
}

public enum LocalLinuxTerminalShellConfiguration {
    public static let defaultPath = "/bin/sh"

    static let commonPaths = [
        defaultPath,
        "/bin/ash",
        "/bin/bash",
        "/bin/zsh",
        "/usr/bin/bash",
        "/usr/bin/zsh",
        "/usr/bin/fish"
    ]

    public static func normalizedPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return defaultPath
        }
        let normalized = (trimmed as NSString).standardizingPath
        guard normalized != "/" else { return defaultPath }
        return normalized
    }

    public static func loginArguments(for shellPath: String) -> [String] {
        let normalized = normalizedPath(shellPath)
        return [normalized, "-l"]
    }

    static func candidatePaths(shellsFileContents: String?) -> [String] {
        var paths = commonPaths
        if let shellsFileContents {
            paths.append(contentsOf: shellsFileContents.split(whereSeparator: \Character.isNewline).compactMap { line in
                let value = line.trimmingCharacters(in: .whitespaces)
                guard value.hasPrefix("/"), !value.hasPrefix("#") else { return nil }
                return normalizedPath(value)
            })
        }

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

public struct LocalLinuxBridgeTerminalRequest: Equatable, Sendable {
    public let terminalID: UInt64
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String?
    public let columns: UInt16
    public let rows: UInt16

    public init(
        terminalID: UInt64,
        executable: String = "/bin/sh",
        arguments: [String] = ["/bin/sh", "-l"],
        environment: [String: String],
        workingDirectory: String?,
        columns: UInt16,
        rows: UInt16
    ) {
        self.terminalID = terminalID
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.columns = columns
        self.rows = rows
    }
}

public struct LocalLinuxBridgeTerminalResult: Equatable, Sendable {
    public let terminalID: UInt64
    public let completionReason: LocalLinuxCompletionReason
    public let exitCode: Int32
    public let terminationSignal: Int32
    public let linuxError: Int32
    public let outputBytes: UInt64
    public let droppedBytes: UInt64
    public let elapsedMilliseconds: UInt64
}

public struct LocalLinuxGuestFileInfo: Equatable, Sendable {
    public let name: String?
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let blocks: UInt64
    public let mode: UInt32
    public let linkCount: UInt32
    public let userID: UInt32
    public let groupID: UInt32
    public let blockSize: UInt32
    public let accessTime: Date
    public let modificationTime: Date
    public let statusChangeTime: Date

    public var isDirectory: Bool { mode & 0o170000 == 0o040000 }
    public var isRegularFile: Bool { mode & 0o170000 == 0o100000 }
    public var isSymbolicLink: Bool { mode & 0o170000 == 0o120000 }
}

public struct LocalLinuxGuestDirectoryPage: Equatable, Sendable {
    public let entries: [LocalLinuxGuestFileInfo]
    public let nextCursor: UInt64
    public let isComplete: Bool
}

public struct LocalLinuxGuestFileReadResult: Equatable, Sendable {
    public let data: Data
    public let totalSize: UInt64
    public let isComplete: Bool
}

public struct LocalLinuxBridgeDiagnosticEvent: Codable, Equatable, Sendable {
    public let category: UInt32
    public let kind: UInt32
    public let scope: UInt32
    public let architecture: UInt32
    public let backend: UInt32
    public let linuxError: Int32
    public let signal: Int32
    public let opcode: UInt32
    public let sequence: UInt64
    public let requestID: UInt64
    public let guestProgramCounter: UInt64
    public let systemCallNumber: UInt64
    public let guestProcessID: UInt32
    public let guestThreadGroupID: UInt32
    public let processName: String?
    public let systemCallName: String?
    public let buildIdentity: String
}

struct LocalLinuxBridgeUUIDParts: Equatable, Sendable {
    let high: UInt64
    let low: UInt64

    init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    init(_ id: UUID) {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        high = bytes.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
        low = bytes.suffix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    var uuid: UUID {
        let bytes = (0..<16).map { index -> UInt8 in
            let source = index < 8 ? high : low
            let shift = UInt64((7 - (index % 8)) * 8)
            return UInt8((source >> shift) & 0xff)
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        return UUID(uuidString: value)!
    }
}

enum LocalLinuxBridgeConstants {
    static let linuxEAGAIN: Int32 = -11
    static let linuxESHUTDOWN: Int32 = -108
    static let timeoutDisabled = UInt32.max
    static let outputLimitDisabled = UInt64.max
    static let outputChunkBytes = 16_384
    static let rootFSInstalled: Int32 = 0
    static let rootFSAlreadyPresent: Int32 = 1
    static let mountReadOnly: Int32 = 1
    static let mountReadWrite: Int32 = 2
    static let capabilityPTY: UInt64 = 1
    static let capabilityLiveMounts: UInt64 = 2
    static let capabilityDiagnostics: UInt64 = 4
    static let capabilityGuestFiles: UInt64 = 8
}

extension LocalLinuxMountAccess {
    var bridgeRawValue: Int32 {
        switch self {
        case .readOnly: return LocalLinuxBridgeConstants.mountReadOnly
        case .readWrite: return LocalLinuxBridgeConstants.mountReadWrite
        }
    }

    init?(bridgeRawValue: Int32) {
        switch bridgeRawValue {
        case LocalLinuxBridgeConstants.mountReadOnly: self = .readOnly
        case LocalLinuxBridgeConstants.mountReadWrite: self = .readWrite
        default: return nil
        }
    }
}

extension LocalLinuxCompletionReason {
    init(commandBridgeRawValue value: Int32) {
        switch value {
        case 1: self = .exited
        case 2: self = .signaled
        case 3: self = .cancelled
        case 4: self = .timedOut
        case 5: self = .outputLimit
        default: self = .runtimeFailure
        }
    }

    init(terminalBridgeRawValue value: Int32) {
        switch value {
        case 1: self = .exited
        case 2: self = .signaled
        case 3: self = .cancelled
        default: self = .runtimeFailure
        }
    }
}
