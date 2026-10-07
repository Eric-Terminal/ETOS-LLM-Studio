import Combine
import ETOSCore
import Foundation
import SwiftUI

@MainActor
final class MacWorldbookModel: ObservableObject {
    @Published private(set) var snapshot = MacWorldbookSnapshot.prepare([], query: "")
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var importReport: WorldbookImportReport?
    @Published private(set) var importDetails = ""
    @Published private(set) var downloadProgress: SyncPackageDownloadProgress?
    @Published var error: String?
    @Published var query = "" { didSet { reload() } }
    private weak var workspace: MacWorkspaceModel?
    private var service: ChatService?
    private var subscriptions = Set<AnyCancellable>()
    private var loadingTask: Task<Void, Never>?
    private var downloadID: UUID?

    func start(service: ChatService, workspace: MacWorkspaceModel) {
        guard self.service == nil else { return }
        self.service = service
        self.workspace = workspace
        NotificationCenter.default.publisher(for: WorldbookStore.didChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }.store(in: &subscriptions)
        AppConfigStore.shared.$appLanguage.dropFirst().sink { [weak self] _ in self?.reload() }.store(in: &subscriptions)
        reload()
    }

    func reload() {
        guard let service else { return }
        loadingTask?.cancel()
        let query = query
        isLoading = true
        loadingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .userInitiated) {
                MacWorldbookSnapshot.prepare(service.loadWorldbooks(), query: query)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.snapshot = snapshot
            isLoading = false
        }
    }

    func reloadAfterRestore() {
        loadingTask?.cancel()
        snapshot = MacWorldbookSnapshot.prepare([], query: "")
        importReport = nil
        importDetails = ""
        error = nil
        reload()
    }

    func save(_ draft: Worldbook, replacing original: Worldbook?) async throws {
        try await perform { try $0.saveWorldbookDraft(draft, replacing: original) }
    }

    func saveEntry(_ draft: MacWorldbookEntryDraft, in original: Worldbook) async throws {
        try await perform { service in
            var book = original
            let entry = try draft.preparedEntry()
            if let index = book.entries.firstIndex(where: { $0.id == entry.id }) { book.entries[index] = entry }
            else { book.entries.append(entry) }
            try service.saveWorldbookDraft(book, replacing: original)
        }
    }

    func moveBooks(from indices: IndexSet, to destination: Int) async throws {
        guard query.isEmpty else { return }
        let originals = snapshot.allBooks
        try await perform { service in
            var reordered = originals
            reordered.move(fromOffsets: indices, toOffset: destination)
            try service.reorderWorldbookDraft(reordered.map(\.id), replacing: originals)
        }
    }

    func moveEntries(in original: Worldbook, from indices: IndexSet, to destination: Int) async throws {
        try await perform { service in
            var book = original
            book.entries.move(fromOffsets: indices, toOffset: destination)
            // 列表顺序与注入优先级同时更新，不能移动后又按旧 order 排回原位。
            for index in book.entries.indices { book.entries[index].order = book.entries.count - index }
            try service.saveWorldbookDraft(book, replacing: original)
        }
    }

    func delete(_ original: Worldbook, entryID: UUID? = nil) async throws {
        try await perform { service in
            if let entryID {
                var book = original
                book.entries.removeAll { $0.id == entryID }
                try service.saveWorldbookDraft(book, replacing: original)
            } else if !service.deleteWorldbook(id: original.id, expected: original) {
                throw WorldbookDraftWriteError.writeFailed
            }
        }
    }

    func importFile(_ url: URL) async throws {
        let result = try await perform { service in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let report = try service.importWorldbook(data: Data(contentsOf: url), fileName: url.lastPathComponent)
            return (report, report.failureReasons.joined(separator: "\n"))
        }
        importReport = result.0
        importDetails = result.1
    }

    func importURL(_ text: String) async throws {
        guard !isWorking else { throw MacMemoryWriteError.busy }
        let id = UUID()
        downloadID = id
        downloadProgress = nil
        defer { downloadID = nil; downloadProgress = nil }
        let result = try await perform { [weak self] service in
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw MacWorldbookURLImportError.empty }
            guard let url = URL(string: text), url.host != nil else { throw MacWorldbookURLImportError.invalid }
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw MacWorldbookURLImportError.scheme }
            var request = URLRequest(url: url)
            request.timeoutInterval = 45
            let (downloaded, response) = try await SyncPackageUploadService.downloadTemporaryFile(request: request) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, downloadID == id else { return }
                    downloadProgress = progress
                }
            }
            defer { try? FileManager.default.removeItem(at: downloaded) }
            try Task.checkCancellation()
            if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
                throw MacWorldbookURLImportError.http(response.statusCode)
            }
            let data = try Data(contentsOf: downloaded)
            try Task.checkCancellation()
            let name = response.suggestedFilename ?? (url.lastPathComponent.isEmpty ? "worldbook.json" : url.lastPathComponent)
            let report = try service.importWorldbook(data: data, fileName: name)
            return (report, report.failureReasons.joined(separator: "\n"))
        }
        importReport = result.0
        importDetails = result.1
    }

    func export(_ book: Worldbook, to url: URL) async throws {
        try await perform { service in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let result = try service.exportWorldbook(id: book.id)
            try result.data.write(to: url, options: .atomic)
        }
    }

    func saveBindings(_ ids: Set<UUID>, replacing original: ChatSession) async throws {
        try await perform { service in
            guard let current = service.chatSessionsSubject.value.first(where: { $0.id == original.id }),
                  current.lorebookIDs == original.lorebookIDs else { throw WorldbookDraftWriteError.changedExternally }
            let available = Set(service.loadWorldbooks().map(\.id))
            guard ids.subtracting(original.lorebookIDs).isSubset(of: available) else { throw WorldbookDraftWriteError.changedExternally }
            service.assignWorldbooks(to: original.id, worldbookIDs: ids.sorted { $0.uuidString < $1.uuidString })
        }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (ChatService) async throws -> T) async throws -> T {
        guard let service, let workspace, !isWorking, !workspace.isRestoringData, !workspace.isExportingSnapshot,
              !workspace.isMutatingHistory, !workspace.sessionLibrary.isWorking, AppLockManager.shared.state != .locked else {
            throw MacMemoryWriteError.busy
        }
        isWorking = true
        error = nil
        defer { isWorking = false; reload() }
        let task = Task.detached(priority: .userInitiated) { try await operation(service) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

private enum MacWorldbookURLImportError: LocalizedError {
    case empty, invalid, scheme, http(Int)
    var errorDescription: String? {
        switch self {
        case .empty: return NSLocalizedString("链接不能为空。", comment: "")
        case .invalid: return NSLocalizedString("链接格式无效，请输入完整 URL。", comment: "")
        case .scheme: return NSLocalizedString("仅支持 http/https 链接。", comment: "")
        case .http(let status): return String(format: NSLocalizedString("下载失败：HTTP %d", comment: ""), status)
        }
    }
}
