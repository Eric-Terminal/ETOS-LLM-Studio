import Foundation
import os.log

enum LocalDebugDocumentReplacementError: LocalizedError, Equatable {
    case incompleteUpload
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .incompleteUpload:
            NSLocalizedString("The upload is incomplete. The original files have been kept.", comment: "调试全量上传缺少文件")
        case .rollbackFailed(let path):
            String(format: NSLocalizedString("File replacement could not be rolled back completely. Recovery files were kept at %@.", comment: "调试文件恢复目录"), path)
        }
    }
}

/// 接收期间只写私有暂存目录；提交由外层暂停所有写入者后调用，不能与运行中的数据库并行。
struct LocalDebugDocumentReplacement: Sendable {
    let root: URL
    let workingDirectory: URL
    let incomingDirectory: URL
    let recoveryDirectory: URL
    let paths: [String]
    private let expectedPaths: Set<String>
    private let commitMarker: URL

    private static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "LocalDebugReplacement")

    init(root: URL, paths: [String]) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        // 同卷重命名避免跨卷拷贝到一半失败；目录位于 Documents 之外，不会被自身扫描或覆盖。
        workingDirectory = self.root.deletingLastPathComponent()
            .appendingPathComponent(".ETOS-Debug-Upload-\(UUID().uuidString)", isDirectory: true)
        incomingDirectory = workingDirectory.appendingPathComponent("Incoming", isDirectory: true)
        recoveryDirectory = workingDirectory.appendingPathComponent("Original", isDirectory: true)
        commitMarker = workingDirectory.appendingPathComponent("CommitStarted")
        let incomingAccess = LocalDebugFileAccess(root: incomingDirectory)
        // 全量替换不经过旧目录中的链接；按空暂存树校验，旧条目稍后整体移入恢复目录。
        try incomingAccess.validateUploadPaths(paths)
        let normalizedPaths = try paths.map { path in
            String(try incomingAccess.url(for: path).path.dropFirst(incomingAccess.root.path.count + 1))
        }.sorted()
        self.paths = normalizedPaths
        expectedPaths = Set(normalizedPaths)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: workingDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(at: incomingDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            try? manager.removeItem(at: workingDirectory)
            throw error
        }
    }

    func receive(path: String, base64: String) throws {
        let access = LocalDebugFileAccess(root: incomingDirectory)
        let destination = try access.url(for: path)
        let relativePath = String(destination.path.dropFirst(access.root.path.count + 1))
        guard expectedPaths.contains(relativePath) else { throw LocalDebugDocumentReplacementError.incompleteUpload }
        // 文件系统自身也参与检测大小写或 Unicode 等价名称冲突，不能悄悄覆盖前一项。
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LocalDebugFileAccessError.conflictingPaths }
        try access.upload(path: relativePath, base64: base64)
    }

    func validateComplete() throws {
        let scan = try LocalDebugFileAccess(root: incomingDirectory).scan()
        guard scan.skippedPaths.isEmpty, scan.paths == paths else { throw LocalDebugDocumentReplacementError.incompleteUpload }
    }

    /// 提交开始后不响应取消；只能成功安装或尝试完整回滚，外层必须等待方法实际返回。
    func commit(
        prepare: @Sendable () throws -> Void = {},
        move: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws {
        try validateComplete()
        // 数据库校验可能整理上传的 WAL/SHM；必须先确认原始清单完整，再允许受控预处理。
        try prepare()
        try Task.checkCancellation()
        let manager = FileManager.default
        let originals = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let incoming = try manager.contentsOfDirectory(at: incomingDirectory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var saved: [URL] = [], installed: [URL] = []
        // 标记必须先于第一次移动落盘；失败回滚和进程中断后，通用清理都不能删除恢复材料。
        try Data().write(to: commitMarker, options: .atomic)
        do {
            for original in originals {
                let backup = recoveryDirectory.appendingPathComponent(original.lastPathComponent)
                try move(original, backup)
                saved.append(backup)
            }
            for source in incoming {
                let destination = root.appendingPathComponent(source.lastPathComponent)
                try move(source, destination)
                installed.append(destination)
            }
        } catch {
            let installationError = error
            var rollbackError: Error?
            // 已安装的新内容先移回暂存区，恢复失败时两边的数据都留给后续恢复处理。
            for destination in installed.reversed() {
                do { try move(destination, incomingDirectory.appendingPathComponent(destination.lastPathComponent)) }
                catch { rollbackError = rollbackError ?? error }
            }
            for backup in saved.reversed() {
                do { try move(backup, root.appendingPathComponent(backup.lastPathComponent)) }
                catch { rollbackError = rollbackError ?? error }
            }
            if let rollbackError {
                Self.logger.error("文件替换回滚失败，保留恢复目录：\(self.workingDirectory.path)，\(rollbackError.localizedDescription)")
                throw LocalDebugDocumentReplacementError.rollbackFailed(workingDirectory.path)
            }
            removeWorkingDirectory()
            throw installationError
        }
        removeWorkingDirectory()
    }

    /// 接收失败或取消后清理暂存；回滚残留存在时绝不能把仅存的原文件一并删除。
    func discard() {
        guard !FileManager.default.fileExists(atPath: commitMarker.path) else { return }
        do {
            let retained = try FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil)
            guard retained.isEmpty else { return }
        } catch {
            let error = error as NSError
            guard error.domain == NSCocoaErrorDomain,
                  error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError else { return }
        }
        removeWorkingDirectory()
    }

    private func removeWorkingDirectory() {
        do { try FileManager.default.removeItem(at: workingDirectory) }
        catch {
            let error = error as NSError
            guard error.domain != NSCocoaErrorDomain || (error.code != NSFileNoSuchFileError && error.code != NSFileReadNoSuchFileError) else { return }
            Self.logger.error("清理调试上传暂存目录失败：\(self.workingDirectory.path)，\(error.localizedDescription)")
        }
    }
}
