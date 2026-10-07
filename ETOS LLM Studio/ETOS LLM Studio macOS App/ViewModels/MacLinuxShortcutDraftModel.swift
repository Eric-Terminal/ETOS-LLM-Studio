import Combine
import ETOSCore
import Foundation

struct MacLinuxKeyChoice: Identifiable, Sendable {
    let key: LocalLinuxTerminalKey
    let title: String
    var id: String { key.rawValue }
}

struct MacLinuxKeyGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let choices: [MacLinuxKeyChoice]
}

@MainActor
final class MacLinuxShortcutDraftModel: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var groups: [MacLinuxKeyGroup] = []
    @Published private(set) var selected: Set<LocalLinuxTerminalKey> = []
    @Published private(set) var guideKeys: JSONValue = .array([])
    @Published private(set) var prepared: LocalLinuxTerminalShortcut?
    @Published private(set) var isPreparing = false
    private let id: UUID
    private var keys: [LocalLinuxTerminalKey]
    private var task: Task<Void, Never>?
    private var version = UUID()

    init(_ original: LocalLinuxTerminalShortcut?) { id = original?.id ?? UUID(); keys = original?.keys ?? [] }

    func toggle(_ key: LocalLinuxTerminalKey) {
        if let index = keys.firstIndex(of: key) { keys.remove(at: index) } else { keys.append(key) }
        refresh()
    }
    func replace(_ keys: [LocalLinuxTerminalKey]) { self.keys = keys; refresh() }

    func refresh() {
        stop(); isPreparing = true
        let version = version, keys = keys, id = id
        task = Task { [weak self] in
            let work = Task.detached(priority: .utility) {
                let shortcut = LocalLinuxTerminalShortcut(id: id, keys: keys)
                let groups = [
                    MacLinuxKeyGroup(id: "modifiers", title: NSLocalizedString("修饰键", comment: ""), choices: LocalLinuxTerminalKey.modifierKeys.map { MacLinuxKeyChoice(key: $0, title: $0.title) }),
                    MacLinuxKeyGroup(id: "typing", title: NSLocalizedString("按键", comment: ""), choices: LocalLinuxTerminalKey.typingKeys.map { MacLinuxKeyChoice(key: $0, title: $0.title) }),
                    MacLinuxKeyGroup(id: "navigation", title: NSLocalizedString("导航键", comment: ""), choices: LocalLinuxTerminalKey.navigationKeys.map { MacLinuxKeyChoice(key: $0, title: $0.title) })
                ]
                return (shortcut, shortcut.title, Set(shortcut.keys), GuideLocalLinuxTerminalShortcutSettingsSupport.keyValue(shortcut.keys), groups, !shortcut.inputData.isEmpty)
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, self.version == version, !Task.isCancelled else { return }
            title = result.1; selected = result.2; guideKeys = result.3; groups = result.4
            prepared = result.5 ? result.0 : nil; isPreparing = false
        }
    }

    func stop() { task?.cancel(); version = UUID(); isPreparing = false; prepared = nil }
}
