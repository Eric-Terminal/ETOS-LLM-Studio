import Foundation

public struct SkillLibraryFile: Identifiable, Sendable {
    public let reference: SkillFileReference
    public let editableContent: String?
    public var id: String { reference.relativePath }
}

public struct SkillLibraryDetail: Sendable {
    public let metadata: SkillMetadata
    public let content: String
    public let body: String
    public let files: [SkillLibraryFile]
    public let versionDigest: String
    public let executionPolicy: SkillExecutionPolicyStatus
}

public enum SkillLibraryMutation: Sendable {
    case groupEnabled(Bool)
    case skillEnabled(name: String, enabled: Bool)
    case manifest(originalName: String?, expectedVersion: String?, content: String, fallbackName: String)
    case install(SkillImportResult, expectedVersion: String?)
    case file(name: String, expectedVersion: String, path: String, creating: Bool, content: String?)
    case delete(name: String, expectedVersion: String)
    case executionPolicy(name: String, expectedVersion: String, original: SkillExecutionPolicyRecord, policy: SkillExecutionPolicy)
}

/// 桌面管理写入串行执行；文件与目录扫描不经过 MainActor，恢复和退出可以等待整次写入。
actor SkillLibraryWorker {
    private var revision: UInt64 = 0

    func snapshot() throws -> SkillLibraryState {
        guard let settings = Persistence.withConfigDatabaseRead({ try SkillLibrarySettings.read(in: $0) }) else {
            throw SkillLibraryError.persistenceFailed
        }
        revision &+= 1
        return SkillLibraryState(revision: revision, skills: SkillStore.listSkills(),
                                 enabledNames: settings.0, chatToolsEnabled: settings.1)
    }

    func detail(name: String) throws -> SkillLibraryDetail {
        let metadata = try metadata(name: name)
        let frozen = try SkillRunSnapshotBuilder.build(skill: metadata)
        guard let content = SkillStore.readSkillContent(skillName: name) else { throw SkillStoreError.missingSkillFile }
        let files = SkillStore.listSkillFiles(skillName: name).map { reference in
            // PDF、图片的可读性指模型能够提取内容，不能把提取结果覆盖回原二进制文件。
            let canEdit = reference.isReadableText
                && !SkillResourcePolicy.isExtractableDocumentPath(reference.relativePath)
                && !SkillResourcePolicy.isOCRImagePath(reference.relativePath)
            return SkillLibraryFile(reference: reference,
                editableContent: canEdit ? SkillStore.loadSkillFile(skillName: name, relativePath: reference.relativePath) : nil)
        }
        return SkillLibraryDetail(metadata: metadata, content: content, body: SkillFrontmatterParser.extractBody(content),
                                  files: files, versionDigest: frozen.versionDigest,
                                  executionPolicy: SkillExecutionPolicyStatus(record: Persistence.skillExecutionPolicy(skillName: name),
                                                                            currentVersionDigest: frozen.versionDigest))
    }

    func mutate(_ mutation: SkillLibraryMutation) throws -> (SkillLibraryState, String?) {
        var selectedName: String?
        switch mutation {
        case .groupEnabled(let enabled):
            try SkillLibrarySettings.persist(.group(enabled))
        case .skillEnabled(let name, let enabled):
            _ = try metadata(name: name)
            try SkillLibrarySettings.persist(.enabled(name, enabled))
            selectedName = name
        case .executionPolicy(let name, let version, let original, let policy):
            _ = try checkedMetadata(name: name, expectedVersion: version)
            let current = Persistence.skillExecutionPolicy(skillName: name)
            guard current.policy == original.policy, current.approvedVersionDigest == original.approvedVersionDigest else {
                throw SkillLibraryError.changed
            }
            let record = SkillExecutionPolicyRecord(skillName: name, policy: policy,
                approvedVersionDigest: policy == .allowCurrentVersion ? version : nil)
            guard Persistence.saveSkillExecutionPolicy(record) else { throw SkillLibraryError.persistenceFailed }
            selectedName = name
        case .manifest(let originalName, let expectedVersion, let content, let fallbackName):
            let manifest = try SkillManifestResolver.resolve(content: content, fallbackName: fallbackName)
            var files: [String: Data] = [:]
            if let originalName {
                _ = try checkedMetadata(name: originalName, expectedVersion: expectedVersion)
                guard let originalFiles = SkillStore.readAllSkillFileData(skillName: originalName) else { throw SkillStoreError.fileNotFound }
                files = originalFiles
            }
            if originalName != manifest.name, SkillStore.skillExists(manifest.name) { throw SkillLibraryError.duplicateName }
            files[SkillStore.defaultSkillFileName] = Data(content.utf8)
            let change: SkillLibrarySettings.Change?
            if let originalName { change = originalName == manifest.name ? nil : .renamed(originalName, manifest.name) }
            else { change = .created(manifest.name) }
            try replace(originalName: originalName, targetName: manifest.name, files: files, settings: change)
            selectedName = manifest.name
        case .install(let result, let expectedVersion):
            guard let data = result.files[SkillStore.defaultSkillFileName], let text = String(data: data, encoding: .utf8),
                  try SkillManifestResolver.resolve(content: text, fallbackName: result.skillName).name == result.skillName else {
                throw SkillStoreError.invalidSkillContent
            }
            let exists = SkillStore.skillExists(result.skillName)
            if exists {
                guard expectedVersion != nil else { throw SkillLibraryError.duplicateName }
                _ = try checkedMetadata(name: result.skillName, expectedVersion: expectedVersion)
            } else if expectedVersion != nil { throw SkillLibraryError.changed }
            try replace(originalName: exists ? result.skillName : nil, targetName: result.skillName,
                        files: result.files, settings: .created(result.skillName))
            selectedName = result.skillName
        case .file(let name, let version, let rawPath, let creating, let content):
            _ = try checkedMetadata(name: name, expectedVersion: version)
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path != SkillStore.defaultSkillFileName,
                  SkillResourcePolicy.normalizeRelativePath(path) == path,
                  let root = SkillStore.resolveSkillDir(skillName: name),
                  SkillPaths.resolveSkillFile(skillDir: root, relativePath: path) != nil,
                  var files = SkillStore.readAllSkillFileData(skillName: name) else { throw SkillStoreError.invalidPath }
            if creating, files[path] != nil { throw SkillLibraryError.duplicateName }
            if !creating, files[path] == nil { throw SkillStoreError.fileNotFound }
            if let content { files[path] = Data(content.utf8) }
            else {
                guard files.removeValue(forKey: path) != nil else { throw SkillStoreError.fileNotFound }
            }
            try replace(originalName: name, targetName: name, files: files, settings: nil)
            selectedName = name
        case .delete(let name, let version):
            _ = try checkedMetadata(name: name, expectedVersion: version)
            try replace(originalName: name, targetName: name, files: nil, settings: .deleted(name))
        }
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        return (try snapshot(), selectedName)
    }

    private func metadata(name: String) throws -> SkillMetadata {
        guard let metadata = SkillStore.listSkills().first(where: { $0.name == name }) else { throw SkillStoreError.fileNotFound }
        return metadata
    }

    private func checkedMetadata(name: String, expectedVersion: String?) throws -> SkillMetadata {
        let metadata = try metadata(name: name)
        guard let expectedVersion, try SkillRunSnapshotBuilder.build(skill: metadata).versionDigest == expectedVersion else {
            throw SkillLibraryError.changed
        }
        return metadata
    }

    private func replace(originalName: String?, targetName: String, files: [String: Data]?, settings: SkillLibrarySettings.Change?) throws {
        guard let target = SkillStore.resolveSkillDir(skillName: targetName) else { throw SkillStoreError.invalidSkillName }
        let original = originalName.flatMap { SkillStore.resolveSkillDir(skillName: $0) }
        try SkillLibraryFileTransaction.perform(original: original, target: target) {
            if let files {
                let success = originalName.map {
                    SkillStore.replaceSkillDataFilesAtomically(oldSkillName: $0, newSkillName: targetName, files: files)
                } ?? SkillStore.saveSkillDataFilesAtomically(skillName: targetName, files: files)
                guard success else { throw SkillLibraryError.persistenceFailed }
            } else if let originalName {
                guard SkillStore.deleteSkill(name: originalName) else { throw SkillLibraryError.persistenceFailed }
            }
            if let settings { try SkillLibrarySettings.persist(settings) }
        }
    }
}

extension SkillManager {
    public func reloadLibraryInBackground() async throws {
        do {
            let state = try await libraryWorker.snapshot()
            guard !Task.isCancelled else { return }
            applyLibraryState(state)
        } catch {
            if !Task.isCancelled { invalidateLibraryAfterReadFailure() }
            throw error
        }
    }

    public func loadLibraryDetailInBackground(name: String) async throws -> SkillLibraryDetail {
        try await libraryWorker.detail(name: name)
    }

    @discardableResult
    public func mutateLibraryInBackground(_ mutation: SkillLibraryMutation) async throws -> String? {
        let (state, name) = try await libraryWorker.mutate(mutation)
        applyLibraryState(state)
        return name
    }
}
