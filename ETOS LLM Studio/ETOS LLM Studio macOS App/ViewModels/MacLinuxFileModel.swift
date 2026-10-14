import Combine
import ETOSCore
import Foundation

@MainActor
final class MacLinuxFileModel: ObservableObject {
    @Published private(set) var directory: MacLinuxFileDirectory?
    @Published private(set) var lease = UUID()
    @Published private(set) var isWorking = false
    @Published private(set) var needsRepair = false
    @Published var editor: MacLinuxFileEditorTarget?
    @Published var error: String?
    private var isOpen = false
    private var pendingPresentation = false
    private var cancelOperation: (() -> Void)?

    func open() {
        guard !isOpen else { return }
        isOpen = true; lease = UUID()
        load(path: directory?.path ?? "/")
    }

    func close(clearContent: Bool = true) {
        isOpen = false; lease = UUID(); cancelOperation?(); cancelOperation = nil
        isWorking = false; pendingPresentation = false; editor = nil; error = nil
        if clearContent { directory = nil; needsRepair = false }
    }

    func load(path: String? = nil, more: Bool = false) {
        guard !isWorking else { return }
        let path = path ?? directory?.path ?? "/", original = more ? directory : nil
        let lease = lease, revision = LocalLinuxActivityBarrier.shared.revision
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await perform(expectedLease: lease, revision: revision) {
                    let services = await MacLinuxServices.shared.value
                    _ = try await services.runtime.ensureReady(trigger: .guestFileBrowser)
                    try Task.checkCancellation()
                    let snapshot = try await LocalLinuxFileBrowser.shared.directory(path: path,
                        cursor: original?.snapshot.page.nextCursor ?? 0, original: original?.snapshot)
                    return MacLinuxFileDirectory.prepare(snapshot, previous: original?.rows ?? [])
                }
                directory = result; needsRepair = false
            } catch { }
        }
    }

    func open(_ row: MacLinuxFileRow) {
        let lease = lease, revision = LocalLinuxActivityBarrier.shared.revision
        Task { [weak self] in
            guard let self else { return }
            do {
                let result: MacLinuxFileOpenResult = try await perform(expectedLease: lease, revision: revision) {
                    let services = await MacLinuxServices.shared.value
                    _ = try await services.runtime.ensureReady(trigger: .guestFileBrowser)
                    try Task.checkCancellation()
                    switch try await LocalLinuxFileBrowser.shared.open(path: row.node.path) {
                    case .directory(let path): return .directory(path)
                    case .file(let preview): return .file(MacLinuxFileEditorTarget.prepare(preview))
                    }
                }
                switch result {
                case .directory(let path): load(path: path)
                case .file(let target): editor = target
                }
            } catch { }
        }
    }

    func refreshPresentation() {
        guard !isWorking else { pendingPresentation = true; return }
        let directory = directory, editor = editor, lease = lease, revision = LocalLinuxActivityBarrier.shared.revision
        Task { [weak self] in
            guard let self else { return }
            do {
                let values = try await perform(expectedLease: lease, revision: revision) {
                    (directory.map { MacLinuxFileDirectory.prepare($0.snapshot, previous: $0.rows) },
                     editor.map { MacLinuxFileEditorTarget.prepare($0.preview, id: $0.id) })
                }
                self.directory = values.0
                if self.editor?.id == editor?.id { self.editor = values.1 }
            } catch { }
        }
    }

    func save(_ target: MacLinuxFileEditorTarget, content: String) async throws {
        guard editor?.id == target.id else { throw CancellationError() }
        try await perform(expectedLease: lease, revision: LocalLinuxActivityBarrier.shared.revision) {
            // 保存不得自动重装系统；只向打开预览时的现有 guest 文件提交修改。
            try await LocalLinuxFileBrowser.shared.save(target.preview, content: content)
        }
        editor = nil; load()
    }

    func remove(_ target: MacLinuxFileDeletion) {
        let nextPath = directory?.path == target.node.path ? directory?.parentPath ?? "/" : directory?.path ?? "/"
        Task { [weak self] in
            guard let self else { return }
            do {
                let damaged = try await perform(expectedLease: target.lease, revision: target.revision) {
                    try await LocalLinuxFileBrowser.shared.remove(target.node)
                    let damaged = LocalLinuxFileBrowser.isCriticalSystemPath(target.node.path)
                    if damaged {
                        let services = await MacLinuxServices.shared.value
                        try await services.runtime.markSystemDamaged(reason: NSLocalizedString("用户删除了关键 Linux 系统路径。重新启动本地 Linux 后会从内置系统恢复。", comment: ""))
                    }
                    return damaged
                }
                editor = nil
                if damaged { directory = nil; needsRepair = true }
                else { load(path: nextPath) }
            } catch { }
        }
    }

    private func perform<Result: Sendable>(expectedLease: UUID, revision: UUID,
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        guard isOpen, lease == expectedLease, !isWorking, AppConfigStore.boolValue(for: .localLinuxEnabled), !LocalLinuxActivityBarrier.shared.isSuspended,
              AppLockManager.shared.state != .locked else { throw CancellationError() }
        isWorking = true; error = nil
        defer {
            if lease == expectedLease {
                cancelOperation = nil; isWorking = false
                if pendingPresentation {
                    pendingPresentation = false
                    // 等调用方发布新目录或预览后再重做文案，不能用操作开始前的快照覆盖结果。
                    Task { [weak self] in
                        guard let self, self.lease == expectedLease, isOpen else { return }
                        refreshPresentation()
                    }
                }
            }
        }
        let task = Task.detached(priority: .utility) {
            try await LocalLinuxActivityBarrier.shared.withActivity(expectedRevision: revision) {
                try Task.checkCancellation()
                return try await operation()
            }
        }
        cancelOperation = { task.cancel() }
        do {
            let result = try await task.value
            guard lease == expectedLease, isOpen else { throw CancellationError() }
            return result
        } catch {
            if lease == expectedLease, !(error is CancellationError) { self.error = error.localizedDescription }
            throw error
        }
    }
}
