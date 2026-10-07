import Combine
import ETOSCore
import Foundation
import SwiftUI

@MainActor
final class MacRoleplayModel: ObservableObject {
    @Published private(set) var snapshot = MacRoleplaySnapshot()
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published var error: String?
    @Published var query = "" { didSet { reload() } }
    private weak var workspace: MacWorkspaceModel?
    private var service: ChatService?
    private var loadingTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

    func start(service: ChatService, workspace: MacWorkspaceModel) {
        guard self.service == nil else { return }
        self.service = service
        self.workspace = workspace
        NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] notification in
                // 消息变量在流式生成时频繁变化，库目录只监听角色与身份本身的变动。
                if notification.userInfo?[RoleplayStore.changeKindUserInfoKey] as? String == RoleplayStore.libraryChangeKind { self?.reload() }
            }.store(in: &subscriptions)
        AppConfigStore.shared.$appLanguage.dropFirst().sink { [weak self] _ in self?.reload() }.store(in: &subscriptions)
        reload()
    }

    func reload() {
        guard let service else { return }
        loadingTask?.cancel()
        isLoading = true
        let query = query
        loadingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .userInitiated) {
                MacRoleplaySnapshot.prepare(characters: service.loadRoleplayCharacters(), personas: service.loadPersonaProfiles(), query: query)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.snapshot = snapshot
            isLoading = false
        }
    }

    func reloadAfterRestore() {
        loadingTask?.cancel()
        snapshot = MacRoleplaySnapshot()
        error = nil
        reload()
    }

    func save(_ draft: MacRoleplayCharacterDraft) async throws {
        try await perform { service in try service.saveRoleplayCharacterDraft(draft.preparedCharacter(), replacing: draft.original) }
    }

    func save(_ draft: MacRoleplayRegexDraft) async throws {
        try await perform { try $0.saveRoleplayCharacterDraft(draft.preparedCharacter(), replacing: draft.originalCharacter) }
    }

    func save(_ draft: MacRoleplayScriptDraft) async throws {
        try await perform { try $0.saveRoleplayCharacterDraft(draft.preparedCharacter(), replacing: draft.originalCharacter) }
    }

    func deleteContent(_ id: UUID, kind: MacRoleplayContentKind, in original: RoleplayCharacter) async throws {
        try await perform { service in
            var character = original
            switch kind {
            case .regex: character.regexRules.removeAll { $0.id == id }
            case .scripts: character.helperScripts.removeAll { $0.id == id }
            }
            try service.saveRoleplayCharacterDraft(character, replacing: original)
        }
    }

    func moveContent(_ kind: MacRoleplayContentKind, in original: RoleplayCharacter, from offsets: IndexSet, to destination: Int) async throws {
        try await perform { service in
            var character = original
            switch kind {
            case .regex: character.regexRules.move(fromOffsets: offsets, toOffset: destination)
            case .scripts: character.helperScripts.move(fromOffsets: offsets, toOffset: destination)
            }
            try service.saveRoleplayCharacterDraft(character, replacing: original)
        }
    }

    func save(_ draft: PersonaProfile, replacing original: PersonaProfile?, avatarData: Data?) async throws {
        try await perform { try $0.savePersonaDraft(draft, replacing: original, avatarData: avatarData) }
    }

    func delete(_ original: RoleplayCharacter) async throws {
        try await perform { try $0.deleteRoleplayCharacterDraft(original) }
    }

    func delete(_ original: PersonaProfile) async throws {
        try await perform { try $0.deletePersonaDraft(original) }
    }

    func importCard(_ url: URL) async throws {
        try await perform { service in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            _ = try service.importRoleplayCard(data: Data(contentsOf: url), fileName: url.lastPathComponent)
        }
    }

    func importCard(data: Data) async throws {
        try await perform {
            guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw MacRoleplayDraftError.pngRequired }
            _ = try $0.importRoleplayCard(data: data, fileName: "character.png")
        }
    }

    private func perform(_ operation: @escaping @Sendable (ChatService) throws -> Void) async throws {
        guard let service, let workspace, !isWorking, !workspace.isRestoringData, !workspace.isExportingSnapshot,
              !workspace.worldbookModel.isWorking, !workspace.isMutatingHistory, !workspace.sessionLibrary.isWorking,
              AppLockManager.shared.state != .locked else { throw MacMemoryWriteError.busy }
        isWorking = true
        error = nil
        defer { isWorking = false; reload() }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try operation(service)
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
