import Combine
import ETOSCore
import Foundation

@MainActor
final class MacChatQuickActionsModel: ObservableObject {
    @Published private(set) var presentation: MacChatQuickActionPresentation?
    @Published private(set) var revision = UUID()
    @Published private(set) var isPreparing = false
    @Published private(set) var guideValue: JSONValue = .array([])
    @Published private(set) var toolbarGuideValue: JSONValue = .array([])
    private var active = false
    private var subscriptions = Set<AnyCancellable>()
    private var preparation: Task<Void, Never>?
    private var preparedConfiguration = ""
    private var configurationID: String {
        let config = AppConfigStore.shared
        return config.chatQuickActionIDs + "|" + config.chatToolbarActionIDs + "|" + config.appLanguage
    }
    var canEdit: Bool { active && !isPreparing && presentation != nil && preparedConfiguration == configurationID }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value; revision = UUID()
        if !value {
            preparation?.cancel(); presentation = nil; guideValue = .array([]); isPreparing = false
            toolbarGuideValue = .array([]); preparedConfiguration = ""
            return
        }
        if subscriptions.isEmpty {
            AppConfigStore.shared.$chatQuickActionIDs.combineLatest(
                AppConfigStore.shared.$chatToolbarActionIDs, AppConfigStore.shared.$appLanguage
            )
                .receive(on: DispatchQueue.main).sink { [weak self] _, _, language in
                    AppLanguageRuntime.apply(rawValue: language)
                    self?.reload()
                }.store(in: &subscriptions)
        }
        reload()
    }

    private func reload() {
        guard active else { return }
        preparation?.cancel()
        let raw = AppConfigStore.shared.chatQuickActionIDs, token = UUID()
        let toolbarRaw = AppConfigStore.shared.chatToolbarActionIDs
        revision = token; isPreparing = true
        preparation = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                MacChatQuickActionPresentation(rawValue: raw, toolbarRawValue: toolbarRaw)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, active, !Task.isCancelled, revision == token,
                  raw == AppConfigStore.shared.chatQuickActionIDs,
                  toolbarRaw == AppConfigStore.shared.chatToolbarActionIDs else { return }
            presentation = result; guideValue = result.guideValue; isPreparing = false
            toolbarGuideValue = .array(ChatQuickAction.allCases.filter(result.toolbar.contains).map { .string($0.rawValue) })
            preparedConfiguration = configurationID
        }
    }

    func setPlacement(_ action: ChatQuickAction, placement: ChatQuickActionPlacement) {
        guard canEdit, let presentation,
              presentation.rawValue == AppConfigStore.shared.chatQuickActionIDs,
              presentation.toolbarRawValue == AppConfigStore.shared.chatToolbarActionIDs else { return }
        var actions = presentation.selectedRows.map(\.action)
        var toolbar = presentation.toolbar
        if placement == .hidden {
            guard actions.count > 1 else { return }
            actions.removeAll { $0 == action }
        } else if !presentation.selected.contains(action) {
            actions.append(action)
        }
        if placement == .toolbar { toolbar.insert(action) } else { toolbar.remove(action) }
        AppConfigStore.shared.chatToolbarActionIDs = ChatQuickActionSelection.encodeToolbarActions(toolbar)
        save(actions)
    }

    func move(_ action: ChatQuickAction, by offset: Int) {
        guard canEdit, let presentation,
              presentation.rawValue == AppConfigStore.shared.chatQuickActionIDs else { return }
        var actions = presentation.selectedRows.map(\.action)
        guard let index = actions.firstIndex(of: action), actions.indices.contains(index + offset) else { return }
        actions.swapAt(index, index + offset)
        save(actions)
    }

    func applyGuideSelection(_ value: JSONValue) throws {
        guard active, preparedConfiguration == configurationID else { throw GuideError.pageChanged }
        save(try MacChatQuickActionPresentation.guideActions(value))
    }

    func applyGuideToolbarSelection(_ value: JSONValue) throws {
        guard active, preparedConfiguration == configurationID else { throw GuideError.pageChanged }
        let actions = try GuideChatQuickActionSettingsSupport.actions(from: value, allowsEmpty: true)
        toolbarGuideValue = .array(actions.map { .string($0.rawValue) })
        AppConfigStore.shared.chatToolbarActionIDs = ChatQuickActionSelection.encodeToolbarActions(Set(actions))
        preparedConfiguration = configurationID
        reload()
    }

    private func save(_ actions: [ChatQuickAction]) {
        // 保留用户顺序；磁盘写入由 AppConfigStore 排队。
        guideValue = .array(actions.map { .string($0.rawValue) })
        AppConfigStore.shared.chatQuickActionIDs = ChatQuickActionSelection.encode(actions)
        preparedConfiguration = configurationID
        reload()
    }
}
