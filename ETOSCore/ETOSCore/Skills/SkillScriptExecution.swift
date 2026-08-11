// ============================================================================
// SkillScriptExecution.swift
// ETOS LLM Studio
//
// Skill 读取与执行严格分离：只有 scripts/ 内、与 Run 冻结摘要一致的文件才会
// 进入只读 Linux 挂载；命令始终使用 argv，不经过宿主或 guest shell 拼接。
// ============================================================================

import CryptoKit
import Foundation

public enum SkillRunSnapshotBuilder {
    public static func build(skill: SkillMetadata) throws -> SkillRunSnapshot {
        guard SkillPaths.isValidSkillName(skill.name),
              let skillDirectory = SkillStore.resolveSkillDir(skillName: skill.name) else {
            throw SkillStoreError.invalidSkillName
        }
        let canonicalRoot = SkillStore.skillsDirectory.resolvingSymlinksInPath().standardizedFileURL
        let canonicalSkill = skillDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(canonicalSkill, of: canonicalRoot),
              canonicalSkill.lastPathComponent == skill.name else {
            throw SkillExecutionError.invalidScriptPath
        }
        guard let files = SkillStore.readAllSkillFileData(skillName: skill.name), !files.isEmpty else {
            throw SkillStoreError.missingSkillFile
        }

        var scripts: [SkillScriptSnapshot] = []
        var scriptExecutability: [String: Bool] = [:]
        for relativePath in files.keys.sorted() {
            guard let normalized = SkillResourcePolicy.normalizeRelativePath(relativePath),
                  normalized == relativePath,
                  let fileURL = SkillStore.resolveSkillFile(skillName: skill.name, relativePath: relativePath) else {
                throw SkillExecutionError.invalidScriptPath
            }
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw SkillExecutionError.invalidScriptPath
            }
            let canonicalFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
            guard isDescendant(canonicalFile, of: canonicalSkill) else {
                throw SkillExecutionError.invalidScriptPath
            }
            let data = files[relativePath]!
            let hash = sha256(data)
            if relativePath.hasPrefix("scripts/") {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                let isExecutable = permissions & 0o111 != 0
                scriptExecutability[relativePath] = isExecutable
                scripts.append(
                    SkillScriptSnapshot(
                        relativePath: relativePath,
                        sha256: hash,
                        size: data.count,
                        isExecutable: isExecutable
                    )
                )
            }
        }
        return SkillRunSnapshot(
            skillID: skill.name,
            skillName: skill.name,
            versionDigest: versionDigest(files: files, scriptExecutability: scriptExecutability),
            allowedTools: skill.allowedTools,
            scripts: scripts.sorted { $0.relativePath < $1.relativePath }
        )
    }

    public static func buildEnabled(
        skillNames: Set<String>,
        skills: [SkillMetadata]
    ) -> [SkillRunSnapshot] {
        skills
            .filter { skillNames.contains($0.name) }
            .sorted { $0.name < $1.name }
            .compactMap { try? build(skill: $0) }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func versionDigest(
        files: [String: Data],
        scriptExecutability: [String: Bool]
    ) -> String {
        var digestInput = Data()
        for relativePath in files.keys.sorted() {
            let data = files[relativePath]!
            digestInput.append(Data(relativePath.utf8))
            digestInput.append(0)
            digestInput.append(Data(String(data.count).utf8))
            digestInput.append(0)
            digestInput.append(Data(sha256(data).utf8))
            if let isExecutable = scriptExecutability[relativePath] {
                digestInput.append(0)
                digestInput.append(isExecutable ? 0x31 : 0x30)
            }
            digestInput.append(10)
        }
        return sha256(digestInput)
    }

    static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.path == "/" ? "/" : root.path + "/"
        return candidate.path.hasPrefix(rootPath)
    }
}

public actor SkillExecutionPackageStore {
    public static let shared = SkillExecutionPackageStore()

    private let fileManager = FileManager.default

    /// 物化目录由版本摘要命名且只创建一次。同一版本的并发执行共享同一只读挂载源。
    public func materialize(
        skillName: String,
        frozenSnapshot: SkillRunSnapshot
    ) throws -> URL {
        guard frozenSnapshot.skillName == skillName,
              frozenSnapshot.versionDigest.count == 64,
              frozenSnapshot.versionDigest.allSatisfy({ $0.isHexDigit }),
              let sourceFiles = SkillStore.readAllSkillFileData(skillName: skillName) else {
            throw SkillExecutionError.skillChanged
        }
        let executability = Dictionary(
            uniqueKeysWithValues: frozenSnapshot.scripts.map { ($0.relativePath, $0.isExecutable) }
        )
        guard SkillRunSnapshotBuilder.versionDigest(
            files: sourceFiles,
            scriptExecutability: executability
        ) == frozenSnapshot.versionDigest else {
            throw SkillExecutionError.skillChanged
        }

        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SkillExecutionPackages", isDirectory: true)
        let versionRoot = cacheRoot.appendingPathComponent(frozenSnapshot.versionDigest, isDirectory: true)
        let target = versionRoot.appendingPathComponent(skillName, isDirectory: true)
        let marker = versionRoot.appendingPathComponent(".etos-snapshot-\(skillName)", isDirectory: false)
        var targetIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: target.path, isDirectory: &targetIsDirectory),
           targetIsDirectory.boolValue,
           (try? String(contentsOf: marker, encoding: .utf8)) == frozenSnapshot.versionDigest {
            return target
        }

        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let staging = cacheRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        for relativePath in sourceFiles.keys.sorted() {
            guard let normalized = SkillResourcePolicy.normalizeRelativePath(relativePath), normalized == relativePath else {
                throw SkillExecutionError.invalidScriptPath
            }
            let output = staging.appendingPathComponent(relativePath, isDirectory: false)
            try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sourceFiles[relativePath]!.write(to: output, options: .atomic)
            let permissions = executability[relativePath] == true ? 0o555 : 0o444
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: output.path)
        }
        try fileManager.createDirectory(at: versionRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: staging, to: target)
        try frozenSnapshot.versionDigest.write(to: marker, atomically: true, encoding: .utf8)
        return target
    }
}

public struct ResolvedSkillScript: Equatable, Sendable {
    public let skillDirectory: URL
    public let guestScriptPath: String
    public let executable: String
    public let argumentsPrefix: [String]
    public let requiredInterpreter: String?
    public let snapshot: SkillScriptSnapshot
}

public enum SkillScriptResolver {
    public static func resolve(
        skillName: String,
        relativePath: String,
        frozenSnapshot: SkillRunSnapshot
    ) throws -> ResolvedSkillScript {
        guard frozenSnapshot.skillName == skillName,
              let normalized = SkillResourcePolicy.normalizeRelativePath(relativePath),
              normalized == relativePath,
              normalized.hasPrefix("scripts/"),
              normalized != "scripts/",
              let frozenScript = frozenSnapshot.scripts.first(where: { $0.relativePath == normalized }),
              let skillDirectory = SkillStore.resolveSkillDir(skillName: skillName),
              let fileURL = SkillStore.resolveSkillFile(skillName: skillName, relativePath: normalized) else {
            throw SkillExecutionError.invalidScriptPath
        }

        let canonicalRoot = SkillStore.skillsDirectory.resolvingSymlinksInPath().standardizedFileURL
        let canonicalSkill = skillDirectory.resolvingSymlinksInPath().standardizedFileURL
        let canonicalScripts = canonicalSkill.appendingPathComponent("scripts", isDirectory: true).standardizedFileURL
        let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard SkillRunSnapshotBuilder.isDescendant(canonicalSkill, of: canonicalRoot),
              values.isSymbolicLink != true,
              values.isRegularFile == true else {
            throw SkillExecutionError.invalidScriptPath
        }
        let canonicalFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
        guard SkillRunSnapshotBuilder.isDescendant(canonicalFile, of: canonicalScripts) else {
            throw SkillExecutionError.invalidScriptPath
        }

        let data = try Data(contentsOf: fileURL)
        guard data.count == frozenScript.size,
              SkillRunSnapshotBuilder.sha256(data) == frozenScript.sha256 else {
            throw SkillExecutionError.skillChanged
        }
        let currentMetadata = SkillStore.listSkills().first { $0.name == skillName }
        guard let currentMetadata,
              try SkillRunSnapshotBuilder.build(skill: currentMetadata).versionDigest == frozenSnapshot.versionDigest else {
            throw SkillExecutionError.skillChanged
        }

        let guestPath = "/mnt/etos/skills/\(skillName)/\(normalized)"
        if frozenScript.isExecutable, let interpreter = shebangInterpreter(in: data) {
            return ResolvedSkillScript(
                skillDirectory: canonicalSkill,
                guestScriptPath: guestPath,
                executable: guestPath,
                argumentsPrefix: [],
                requiredInterpreter: interpreter,
                snapshot: frozenScript
            )
        }

        switch fileURL.pathExtension.lowercased() {
        case "sh":
            return interpreted("/bin/sh", guestPath: guestPath, directory: canonicalSkill, snapshot: frozenScript)
        case "py":
            return interpreted("python3", guestPath: guestPath, directory: canonicalSkill, snapshot: frozenScript)
        case "js", "mjs":
            return interpreted("node", guestPath: guestPath, directory: canonicalSkill, snapshot: frozenScript)
        default:
            guard frozenScript.isExecutable, isAArch64ELF(data) else {
                throw SkillExecutionError.unsupportedScript
            }
            return ResolvedSkillScript(
                skillDirectory: canonicalSkill,
                guestScriptPath: guestPath,
                executable: guestPath,
                argumentsPrefix: [],
                requiredInterpreter: nil,
                snapshot: frozenScript
            )
        }
    }

    private static func interpreted(
        _ interpreter: String,
        guestPath: String,
        directory: URL,
        snapshot: SkillScriptSnapshot
    ) -> ResolvedSkillScript {
        ResolvedSkillScript(
            skillDirectory: directory,
            guestScriptPath: guestPath,
            executable: interpreter,
            argumentsPrefix: [guestPath],
            requiredInterpreter: interpreter,
            snapshot: snapshot
        )
    }

    private static func shebangInterpreter(in data: Data) -> String? {
        guard data.count >= 3,
              data[data.startIndex] == 0x23,
              data[data.startIndex + 1] == 0x21 else { return nil }
        let prefix = data.prefix(4_096)
        guard let line = String(data: prefix, encoding: .utf8)?.split(whereSeparator: \.isNewline).first else {
            return nil
        }
        let command = line.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = parts.first, first.hasPrefix("/"), !first.contains("\0") else { return nil }
        if URL(fileURLWithPath: first).lastPathComponent == "env", parts.count >= 2 {
            return parts[1]
        }
        return first
    }

    private static func isAArch64ELF(_ data: Data) -> Bool {
        guard data.count >= 20,
              data[0] == 0x7f,
              data[1] == 0x45,
              data[2] == 0x4c,
              data[3] == 0x46,
              data[4] == 1 || data[4] == 2,
              data[5] == 1 else { return false }
        let machine = UInt16(data[18]) | UInt16(data[19]) << 8
        return machine == 183
    }
}
