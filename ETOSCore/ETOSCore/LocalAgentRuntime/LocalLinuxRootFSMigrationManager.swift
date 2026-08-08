// ============================================================================
// LocalLinuxRootFSMigrationManager.swift
// ============================================================================
// ETOS LLM Studio
//
// RootFS 属于用户可长期修改的环境，App 更新不能用新 seed 覆盖它。只有随 App
// 签名分发、摘要校验通过的固定迁移脚本，才可以把安装收据推进到新 seed。
// ============================================================================

import CryptoKit
import Foundation

public struct LocalLinuxRootFSMigrationDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let fromSeedSHA256: String
    public let toSeedSHA256: String
    public let scriptFile: String
    public let scriptSHA256: String
}

public struct LocalLinuxRootFSMigrationManifest: Codable, Equatable, Sendable {
    public let format: String
    public let targetSeedSHA256: String
    public let migrations: [LocalLinuxRootFSMigrationDefinition]
}

public struct LocalLinuxRootFSMigrationResource: Equatable, Sendable {
    public let manifestURL: URL
    public let manifest: LocalLinuxRootFSMigrationManifest
    public let scriptURLs: [String: URL]

    public static func load(
        from bundle: Bundle = .main,
        targetSeedSHA256: String
    ) throws -> LocalLinuxRootFSMigrationResource {
        guard let manifestURL = resourceURL(
            bundle: bundle,
            name: "ETOSLocalLinuxRootFSMigrations",
            extension: "json"
        ) else {
            throw LocalLinuxRuntimeError.seedResourceMissing
        }
        let manifest = try JSONDecoder().decode(
            LocalLinuxRootFSMigrationManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        try validate(manifest: manifest, targetSeedSHA256: targetSeedSHA256)

        var scriptURLs: [String: URL] = [:]
        for migration in manifest.migrations {
            let scriptName = migration.scriptFile as NSString
            guard scriptName.lastPathComponent == migration.scriptFile,
                  !migration.scriptFile.isEmpty,
                  let scriptURL = resourceURL(
                    bundle: bundle,
                    name: scriptName.deletingPathExtension,
                    extension: scriptName.pathExtension.isEmpty ? nil : scriptName.pathExtension
                  ) else {
                throw LocalLinuxRuntimeError.invalidSeedMetadata("migration.scriptFile")
            }
            let digest = SHA256.hash(data: try Data(contentsOf: scriptURL))
                .map { String(format: "%02x", $0) }
                .joined()
            guard digest.caseInsensitiveCompare(migration.scriptSHA256) == .orderedSame else {
                throw LocalLinuxRuntimeError.invalidSeedMetadata("migration.scriptSHA256")
            }
            scriptURLs[migration.id] = scriptURL
        }
        return LocalLinuxRootFSMigrationResource(
            manifestURL: manifestURL,
            manifest: manifest,
            scriptURLs: scriptURLs
        )
    }

    public func migrationPath(from installedSeedSHA256: String) throws -> [LocalLinuxRootFSMigrationDefinition] {
        var current = installedSeedSHA256.lowercased()
        let target = manifest.targetSeedSHA256.lowercased()
        guard current != target else { return [] }

        let migrationsBySource = Dictionary(
            uniqueKeysWithValues: manifest.migrations.map { ($0.fromSeedSHA256.lowercased(), $0) }
        )
        var visited: Set<String> = []
        var path: [LocalLinuxRootFSMigrationDefinition] = []
        while current != target {
            guard visited.insert(current).inserted,
                  let migration = migrationsBySource[current] else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString(
                        "内置 Linux 系统没有适用于当前 RootFS 的更新路径；现有文件未被修改。请继续使用当前 App 版本，或手动重置系统。",
                        comment: "Missing RootFS migration path"
                    )
                )
            }
            path.append(migration)
            current = migration.toSeedSHA256.lowercased()
        }
        return path
    }

    private static func validate(
        manifest: LocalLinuxRootFSMigrationManifest,
        targetSeedSHA256: String
    ) throws {
        guard manifest.format == "etos-rootfs-migrations-v1",
              isSHA256(manifest.targetSeedSHA256),
              manifest.targetSeedSHA256.caseInsensitiveCompare(targetSeedSHA256) == .orderedSame else {
            throw LocalLinuxRuntimeError.invalidSeedMetadata("migrationManifest")
        }
        var ids: Set<String> = []
        var sources: Set<String> = []
        let allowedID = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        for migration in manifest.migrations {
            guard !migration.id.isEmpty,
                  migration.id.unicodeScalars.allSatisfy(allowedID.contains),
                  ids.insert(migration.id).inserted,
                  isSHA256(migration.fromSeedSHA256),
                  isSHA256(migration.toSeedSHA256),
                  isSHA256(migration.scriptSHA256),
                  migration.fromSeedSHA256.caseInsensitiveCompare(migration.toSeedSHA256) != .orderedSame,
                  sources.insert(migration.fromSeedSHA256.lowercased()).inserted else {
                throw LocalLinuxRuntimeError.invalidSeedMetadata("migration")
            }
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func resourceURL(
        bundle: Bundle,
        name: String,
        extension fileExtension: String?
    ) -> URL? {
        bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "LocalLinux")
            ?? bundle.url(forResource: name, withExtension: fileExtension)
    }
}

private struct LocalLinuxRootFSMigrationState: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case running
        case completed
        case failed
    }

    let migrationID: String
    let scriptSHA256: String
    let fromSeedSHA256: String
    let toSeedSHA256: String
    let status: Status
    let updatedAt: Date
}

private final class LocalLinuxRootFSMigrationOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maximumBytes = 1_048_576

    func append(stream: LocalLinuxOutputStream, bytes: Data, terminalError: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < maximumBytes else { return }
        let prefix = stream == .stderr ? "[stderr] " : "[stdout] "
        data.append(contentsOf: prefix.utf8)
        data.append(bytes.prefix(maximumBytes - data.count))
        if terminalError != 0, data.count < maximumBytes {
            data.append(contentsOf: "\n[bridge-error \(terminalError)]\n".utf8)
        }
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

public actor LocalLinuxRootFSMigrationManager {
    public static let shared = LocalLinuxRootFSMigrationManager()

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func apply(
        _ migrations: [LocalLinuxRootFSMigrationDefinition],
        resource: LocalLinuxRootFSMigrationResource,
        storage: LocalLinuxStorageManager,
        bridge: iSHAppleBridgeAdapter
    ) async throws {
        guard !migrations.isEmpty else { return }
        let layout = storage.layout
        let directory = layout.system.appendingPathComponent("Migrations", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for migration in migrations {
            let stateURL = directory.appendingPathComponent("\(migration.id).json", isDirectory: false)
            if try completedStateMatches(at: stateURL, migration: migration) { continue }
            guard let scriptURL = resource.scriptURLs[migration.id] else {
                throw LocalLinuxRuntimeError.invalidSeedMetadata("migration.scriptFile")
            }

            try writeState(.running, migration: migration, to: stateURL)
            let output = LocalLinuxRootFSMigrationOutput()
            do {
                let requestID = UInt64.random(in: 1 ... UInt64.max)
                let session = try await bridge.startCommand(
                    requestID: requestID,
                    request: LocalLinuxJobRequest(
                        executable: "/bin/sh",
                        arguments: ["/bin/sh", "-eu", "-s"],
                        environment: [
                            "HOME": "/root",
                            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                            "TERM": "dumb"
                        ],
                        workingDirectory: "/",
                        timeoutSeconds: 0,
                        outputLimitBytes: 1_048_576
                    )
                ) { stream, data, terminalError in
                    output.append(stream: stream, bytes: data, terminalError: terminalError)
                }
                var script = try Data(contentsOf: scriptURL)
                if script.last != 0x0A { script.append(0x0A) }
                try await session.send(script)
                try session.finishInput()
                let result = await session.result()
                try writeLog(output.snapshot(), result: result, migration: migration, directory: directory)
                guard result.completionReason == .exited, result.exitCode == 0 else {
                    try writeState(.failed, migration: migration, to: stateURL)
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        String(
                            format: NSLocalizedString("Linux 系统更新“%@”失败（退出码 %d）；现有 RootFS 已保留。", comment: "RootFS migration command failed"),
                            migration.id,
                            result.exitCode
                        )
                    )
                }
                try writeState(.completed, migration: migration, to: stateURL)
            } catch {
                try? writeState(.failed, migration: migration, to: stateURL)
                throw error
            }
        }
        try await storage.recordInstalledSeedSHA256(resource.manifest.targetSeedSHA256)
    }

    private func completedStateMatches(
        at url: URL,
        migration: LocalLinuxRootFSMigrationDefinition
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let state = try JSONDecoder().decode(LocalLinuxRootFSMigrationState.self, from: Data(contentsOf: url))
        return state.status == .completed
            && state.migrationID == migration.id
            && state.scriptSHA256.caseInsensitiveCompare(migration.scriptSHA256) == .orderedSame
            && state.fromSeedSHA256.caseInsensitiveCompare(migration.fromSeedSHA256) == .orderedSame
            && state.toSeedSHA256.caseInsensitiveCompare(migration.toSeedSHA256) == .orderedSame
    }

    private func writeState(
        _ status: LocalLinuxRootFSMigrationState.Status,
        migration: LocalLinuxRootFSMigrationDefinition,
        to url: URL
    ) throws {
        let state = LocalLinuxRootFSMigrationState(
            migrationID: migration.id,
            scriptSHA256: migration.scriptSHA256.lowercased(),
            fromSeedSHA256: migration.fromSeedSHA256.lowercased(),
            toSeedSHA256: migration.toSeedSHA256.lowercased(),
            status: status,
            updatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func writeLog(
        _ output: Data,
        result: LocalLinuxBridgeCommandResult,
        migration: LocalLinuxRootFSMigrationDefinition,
        directory: URL
    ) throws {
        var log = Data("migration=\(migration.id)\nreason=\(result.completionReason.rawValue)\nexit_code=\(result.exitCode)\n".utf8)
        log.append(output)
        try log.write(
            to: directory.appendingPathComponent("\(migration.id).log", isDirectory: false),
            options: .atomic
        )
    }
}
