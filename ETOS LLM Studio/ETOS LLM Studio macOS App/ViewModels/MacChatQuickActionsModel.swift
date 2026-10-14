import Combine
import ETOSCore
import Foundation

@MainActor
final class MacChatQuickActionsModel: ObservableObject {
    @Published private(set) var presentation: MacChatQuickActionPresentation?
    @Published private(set) var revision = UUID()
    @Published private(set) var isPreparing = false
    @Published private(set) var guideValue: JSONValue = .array([])
    private var active = false
    private var subscriptions = Set<AnyCancellable>()
    private var preparation: Task<Void, Never>?
    var canEdit: Bool { active && !isPreparing && presentation != nil }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value; revision = UUID()
        if !value {
            preparation?.cancel(); presentation = nil; guideValue = .array([]); isPreparing = false
            return
        }
        if subscriptions.isEmpty {
            AppConfigStore.shared.$chatQuickActionIDs.combineLatest(AppConfigStore.shared.$appLanguage)
                .receive(on: DispatchQueue.main).sink { [weak self] _, language in
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
        revision = token; isPreparing = true
        preparation = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { MacChatQuickActionPresentation(rawValue: raw) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, active, !Task.isCancelled, revision == token,
                  raw == AppConfigStore.shared.chatQuickActionIDs else { return }
            presentation = result; guideValue = result.guideValue; isPreparing = false
        }
    }

    func setSelected(_ action: ChatQuickAction, enabled: Bool) {
        guard canEdit, let presentation, presentation.rawValue == AppConfigStore.shared.chatQuickActionIDs else { return }
        var selected = presentation.selected
        if !enabled {
            guard selected.contains(action), selected.count > 1 else { return }
            selected.remove(action)
        } else if !selected.insert(action).inserted { return }
        save(ChatQuickAction.allCases.filter { selected.contains($0) })
    }

    func applyGuideSelection(_ value: JSONValue) throws {
        guard canEdit, presentation?.rawValue == AppConfigStore.shared.chatQuickActionIDs else { throw GuideError.pageChanged }
        save(try MacChatQuickActionPresentation.guideActions(value))
    }

    private func save(_ actions: [ChatQuickAction]) {
        // 固定 15 个标识的内存转换在设置事件中完成，磁盘写入由 AppConfigStore 排队。
        guideValue = .array(actions.map { .string($0.rawValue) })
        AppConfigStore.shared.chatQuickActionIDs = ChatQuickActionSelection.encode(actions)
        reload()
    }
}
