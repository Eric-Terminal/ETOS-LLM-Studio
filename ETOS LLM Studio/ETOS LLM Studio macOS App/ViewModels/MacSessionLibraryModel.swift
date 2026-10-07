import Combine
import ETOSCore
import Foundation

@MainActor
final class MacSessionLibraryModel: ObservableObject {
    @Published private(set) var snapshot = MacSessionLibrarySnapshot()
    @Published private(set) var isWorking = false
    @Published var scope: MacSessionScope = .all { didSet { if scope != oldValue { refresh() } } }
    @Published var query = "" { didSet { refresh() } }
    @Published var error: String?
    private weak var workspace: MacWorkspaceModel?
    private var service: ChatService?
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?

    func start(service: ChatService, workspace: MacWorkspaceModel) {
        self.service = service
        self.workspace = workspace
        Publishers.CombineLatest3(service.chatSessionsSubject, service.sessionFoldersSubject, service.sessionTagsSubject)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        service.messagesForSessionSubject
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.global(qos: .utility))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !query.isEmpty else { return }
                refresh()
            }.store(in: &subscriptions)
        service.sessionRequestStatusSubject.receive(on: DispatchQueue.main).sink { [weak self] event in
            guard let self, !query.isEmpty else { return }
            switch event.status {
            case .finished, .error, .cancelled: refresh()
            case .started: break
            }
        }.store(in: &subscriptions)
        AppConfigStore.shared.$appLanguage.dropFirst().sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
    }

    private func refresh() {
        guard let service else { return }
        refreshTask?.cancel()
        let sessions = service.chatSessionsSubject.value
        let folders = service.sessionFoldersSubject.value
        let tags = service.sessionTagsSubject.value
        let scope = scope
        let query = query
        refreshTask = Task { [weak self] in
            // 搜索输入短暂合并；读取历史、正则检索与路径整理均不占主线程。
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                MacSessionLibrarySnapshot.prepare(sessions: sessions, folders: folders, tags: tags, scope: scope, query: query) { id in
                    guard !Task.isCancelled else { return [] }
                    return service.messagesSnapshot(for: id)
                }
            }
            let prepared = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled else { return }
            snapshot = prepared
            if self.scope != prepared.scope { self.scope = prepared.scope }
        }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (ChatService) throws -> T) async throws -> T {
        guard let service, let workspace, !isWorking, !workspace.isRestoringData,
              !workspace.isMutatingHistory, !workspace.isExportingSnapshot,
              AppLockManager.shared.state != .locked else { throw MacMemoryWriteError.busy }
        isWorking = true
        defer { isWorking = false; refresh() }
        return try await Task.detached(priority: .userInitiated) { try operation(service) }.value
    }

    func saveFolder(original: SessionFolder?, name: String, parentID: UUID?) async throws {
        try await perform { service in
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let folders = service.sessionFoldersSubject.value
            guard !name.isEmpty, parentID == nil || folders.contains(where: { $0.id == parentID }) else {
                throw MacSessionLibraryError.invalidDestinationOrName
            }
            if let original {
                guard folders.first(where: { $0.id == original.id }) == original else { throw MacSessionLibraryError.changedExternally }
                var ancestorID = parentID
                var seen: Set<UUID> = [original.id]
                while let id = ancestorID {
                    guard seen.insert(id).inserted else { throw MacSessionLibraryError.invalidDestinationOrName }
                    ancestorID = folders.first(where: { $0.id == id })?.parentID
                }
                service.moveSessionFolder(folderID: original.id, toParentID: parentID)
                service.renameSessionFolder(folderID: original.id, newName: name)
            } else if service.createSessionFolder(name: name, parentID: parentID) == nil {
                throw MacSessionLibraryError.invalidDestinationOrName
            }
        }
    }

    func deleteFolder(_ original: SessionFolder) async throws {
        try await perform { service in
            guard service.sessionFoldersSubject.value.first(where: { $0.id == original.id }) == original else {
                throw MacSessionLibraryError.changedExternally
            }
            service.deleteSessionFolder(folderID: original.id)
        }
    }

    func saveTag(original: SessionTag?, name: String, color: SessionTagColor?) async throws {
        try await perform { service in
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let tags = service.sessionTagsSubject.value
            guard !name.isEmpty, !tags.contains(where: { !$0.isSystemColorTag && $0.id != original?.id && $0.name.lowercased() == name.lowercased() }) else {
                throw MacSessionLibraryError.invalidDestinationOrName
            }
            if let original {
                guard !original.isSystemColorTag, tags.first(where: { $0.id == original.id }) == original else {
                    throw MacSessionLibraryError.changedExternally
                }
                service.updateSessionTag(original, name: name, color: color)
            } else if service.createSessionTag(name: name, color: color) == nil {
                throw MacSessionLibraryError.invalidDestinationOrName
            }
        }
    }

    func deleteTag(_ original: SessionTag) async throws {
        try await perform { service in
            guard !original.isSystemColorTag, service.sessionTagsSubject.value.first(where: { $0.id == original.id }) == original else {
                throw MacSessionLibraryError.changedExternally
            }
            service.deleteSessionTag(original)
        }
    }

    func moveSession(_ session: ChatSession, to folderID: UUID?) {
        Task {
            do {
                try await perform { service in
                    guard service.chatSessionsSubject.value.contains(where: { $0.id == session.id }),
                          folderID == nil || service.sessionFoldersSubject.value.contains(where: { $0.id == folderID }) else {
                        throw MacSessionLibraryError.changedExternally
                    }
                    service.moveSession(sessionID: session.id, toFolderID: folderID)
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func toggleTag(_ tag: SessionTag, for session: ChatSession) {
        Task {
            do {
                try await perform { service in
                    guard service.chatSessionsSubject.value.contains(where: { $0.id == session.id }) else { throw MacSessionLibraryError.changedExternally }
                    if let color = tag.systemColor { service.toggleSessionColorMarker(sessionID: session.id, color: color) }
                    else {
                        guard service.sessionTagsSubject.value.contains(where: { $0.id == tag.id }) else { throw MacSessionLibraryError.changedExternally }
                        service.toggleSessionTag(sessionID: session.id, tagID: tag.id)
                    }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

enum MacSessionLibraryError: LocalizedError {
    case changedExternally, invalidDestinationOrName
    var errorDescription: String? {
        switch self {
        case .changedExternally: NSLocalizedString("会话分类已在其他位置更改，请重新打开后再编辑。", comment: "")
        case .invalidDestinationOrName: NSLocalizedString("名称重复或目标位置已不可用，请刷新后重试。", comment: "")
        }
    }
}
