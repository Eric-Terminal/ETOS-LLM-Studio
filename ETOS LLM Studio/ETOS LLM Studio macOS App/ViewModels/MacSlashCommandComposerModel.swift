import Combine
import ETOSCore
import Foundation

@MainActor
final class MacSlashCommandComposerModel: ObservableObject {
    @Published private(set) var input: MacSlashCommandInput?
    @Published private(set) var selectedIndex = 0
    @Published private(set) var isResolving = false
    private var preparation: Task<Void, Never>?
    private var revision = UUID()
    private var literalPrefill: String?
    private var prefillChangePending = false

    func refresh(text: String, sessionID: UUID?, enabled: Bool, catalog: MacSlashCommandCatalog?, inputChanged: Bool = false) {
        if inputChanged {
            if prefillChangePending { prefillChangePending = false }
            else { literalPrefill = nil }
        }
        preparation?.cancel(); revision = UUID(); input = nil; selectedIndex = 0; isResolving = false
        guard !enabled || catalog != nil || text.first != "/" else { return }
        let expected = revision, commands = catalog?.snapshot.commands ?? [], prefill = literalPrefill
        preparation = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                MacSlashCommandInput(text: text, sessionID: sessionID, enabled: enabled, commands: commands, literalPrefill: prefill)
            }.value
            guard let self, !Task.isCancelled, revision == expected else { return }
            input = result
        }
    }

    func invalidate() {
        preparation?.cancel(); revision = UUID(); input = nil; literalPrefill = nil; prefillChangePending = false; isResolving = false
    }

    func markCustomPrefill(_ prompt: String) {
        literalPrefill = prompt; prefillChangePending = true
        input = nil; preparation?.cancel(); revision = UUID(); isResolving = false
    }

    func moveSelection(_ delta: Int) -> Bool {
        guard let rows = input?.rows, !rows.isEmpty else { return false }
        selectedIndex = min(rows.count - 1, max(0, selectedIndex + delta)); return true
    }

    func selectedSuggestion() -> ChatSlashCommandSuggestion? {
        guard let rows = input?.rows, rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex].suggestion
    }

    func selectID(_ id: String?) {
        guard let id, let index = input?.indicesByID[id] else { return }
        selectedIndex = index
    }

    func dismissSuggestions() { input = nil; preparation?.cancel(); revision = UUID(); isResolving = false }

    /// 提交重新解析当前草稿，不能依赖上一帧的建议去截获刚输入的新消息。
    func resolve(text: String, sessionID: UUID?, enabled: Bool, catalog: MacSlashCommandCatalog?) async -> MacSlashCommandInput? {
        guard !isResolving, !enabled || catalog != nil || text.first != "/" else { return nil }
        let expected = revision, commands = catalog?.snapshot.commands ?? [], prefill = literalPrefill
        isResolving = true
        defer { if revision == expected { isResolving = false } }
        let result = await Task.detached(priority: .userInitiated) {
            MacSlashCommandInput(text: text, sessionID: sessionID, enabled: enabled, commands: commands, literalPrefill: prefill)
        }.value
        guard revision == expected, !Task.isCancelled else { return nil }
        return result
    }
}
