import Foundation
import Combine

public struct ProviderAPIKeyEntry: Identifiable, Equatable {
    public let id: UUID
    public var value: String
    public var note: String

    public init(id: UUID = UUID(), value: String = "", note: String = "") {
        self.id = id
        self.value = value
        self.note = note
    }
}

/// 两端共享草稿与输入校验；渲染时只读取预先更新的计数、有效性和变更标记。
@MainActor
public final class ProviderAPIKeyEditorModel: ObservableObject {
    public struct Draft: Equatable {
        public var entries: [ProviderAPIKeyEntry]
        public var multiKeyEnabled: Bool
        public var maximumRetriesText: String
    }

    @Published public var draft: Draft { didSet { refresh() } }
    @Published public var showsPlaintext = false
    @Published public private(set) var keyCount = 0
    @Published public private(set) var isValid = false
    @Published public private(set) var hasUnsavedChanges = false
    @Published public private(set) var retryInputIsValid = true
    @Published public private(set) var guideSettings: [GuidePageSetting] = []
    public private(set) var keys: [String] = []
    public private(set) var notes: [String: String] = [:]
    private let original: Draft

    public init(provider: Provider) {
        let entries = provider.apiKeys.map {
            ProviderAPIKeyEntry(value: $0, note: provider.apiKeyNotes[$0] ?? "")
        }
        let initial = Draft(
            entries: entries.isEmpty ? [ProviderAPIKeyEntry()] : entries,
            multiKeyEnabled: provider.multiKeyEnabled,
            maximumRetriesText: String(provider.maximumKeyRetries)
        )
        self.draft = initial
        self.original = initial
        refresh()
    }

    public var singleKeyText: String {
        get { draft.entries.first?.value ?? "" }
        set {
            var updated = draft
            if updated.entries.isEmpty { updated.entries.append(ProviderAPIKeyEntry()) }
            let values = Self.split(newValue)
            if values.count > 1 {
                // 批量粘贴展开为独立条目，管理页由用户主动打开。
                let first = updated.entries.removeFirst()
                updated.entries.insert(contentsOf: values.enumerated().map { index, value in
                    ProviderAPIKeyEntry(value: value, note: index == 0 ? first.note : "")
                }, at: 0)
                updated.multiKeyEnabled = true
            } else {
                updated.entries[0].value = newValue
            }
            draft = updated
        }
    }

    public var apiKeysText: String { keys.joined(separator: ",") }

    public func addEntry() {
        draft.entries.append(ProviderAPIKeyEntry())
    }

    public func removeEntry(id: UUID) {
        draft.entries.removeAll { $0.id == id }
    }

    public func replaceKeys(from text: String) {
        var updated = draft
        let values = Self.split(text)
        updated.entries = values.map { ProviderAPIKeyEntry(value: $0, note: notes[$0] ?? "") }
        if updated.entries.isEmpty { updated.entries = [ProviderAPIKeyEntry()] }
        if values.count > 1 { updated.multiKeyEnabled = true }
        draft = updated
    }

    public func apply(to provider: inout Provider) {
        provider.apiKeys = keys
        provider.apiKeyNotes = notes
        provider.multiKeyEnabled = draft.multiKeyEnabled
        provider.maximumKeyRetries = ProviderAPIKeyRetryPolicy.maximumRetries(from: draft.maximumRetriesText)
            ?? provider.maximumKeyRetries
    }

    private static func split(_ text: String) -> [String] {
        ProviderCredentialStore.normalizeAPIKeys(text.components(separatedBy: CharacterSet(charactersIn: ",，\n\r")))
    }

    private func refresh() {
        var preparedKeys: [String] = []
        var preparedNotes: [String: String] = [:]
        var seen = Set<String>()
        for entry in draft.entries {
            for key in Self.split(entry.value) {
                if seen.insert(key).inserted { preparedKeys.append(key) }
                if !entry.note.isEmpty, preparedNotes[key] == nil { preparedNotes[key] = entry.note }
            }
        }
        keys = preparedKeys
        notes = preparedNotes
        keyCount = keys.count
        retryInputIsValid = ProviderAPIKeyRetryPolicy.maximumRetries(from: draft.maximumRetriesText) != nil
        let firstKeyIsValid = draft.entries.first.map { !Self.split($0.value).isEmpty } ?? false
        isValid = (draft.multiKeyEnabled ? !keys.isEmpty : firstKeyIsValid)
            && (!draft.multiKeyEnabled || retryInputIsValid)
        hasUnsavedChanges = draft != original
        guideSettings = makeGuideSettings()
    }

    private func makeGuideSettings() -> [GuidePageSetting] {
        var settings: [GuidePageSetting] = [
            .readOnly("save_behavior", label: NSLocalizedString("保存方式", comment: ""), value: {
                .string(NSLocalizedString("此页修改先保留为草稿，返回提供商页面后点击保存生效。", comment: ""))
            }),
            .bool("multi_key_enabled", label: NSLocalizedString("多 Key 模式", comment: ""),
                  get: { [weak self] in self?.draft.multiKeyEnabled ?? false },
                  set: { [weak self] in self?.draft.multiKeyEnabled = $0 }),
            .integer("maximum_key_retries", label: NSLocalizedString("最大换 Key 次数", comment: ""),
                     range: ProviderAPIKeyRetryPolicy.allowedMaximumRetries,
                     get: { [weak self] in Int(self?.draft.maximumRetriesText ?? "") ?? 3 },
                     set: { [weak self] in self?.draft.maximumRetriesText = String($0) }),
            .readOnly("key_count", label: NSLocalizedString("API Key 数量", comment: ""),
                      value: { [weak self] in .int(self?.keyCount ?? 0) }),
            .writeOnlyString("add_api_key", label: NSLocalizedString("添加 API Key", comment: ""),
                             isConfigured: { false }, set: { [weak self] text in
                self?.draft.entries.append(contentsOf: Self.split(text).map { ProviderAPIKeyEntry(value: $0) })
            })
        ]
        for (index, entry) in draft.entries.enumerated() {
            let prefix = "key_\(entry.id.uuidString.lowercased())"
            let label = String(format: NSLocalizedString("第 %d 个 API Key", comment: ""), index + 1)
            settings.append(.writeOnlyString(prefix, label: label,
                isConfigured: { [weak self] in self?.draft.entries.first { $0.id == entry.id }?.value.isEmpty == false },
                set: { [weak self] value in
                    guard let self, let index = self.draft.entries.firstIndex(where: { $0.id == entry.id }) else { return }
                    self.draft.entries[index].value = value
                }))
            settings.append(.string(prefix + "_note",
                label: String(format: NSLocalizedString("%@ · %@", comment: ""), label, NSLocalizedString("备注", comment: "")),
                get: { [weak self] in self?.draft.entries.first { $0.id == entry.id }?.note ?? "" },
                set: { [weak self] value in
                    guard let self, let index = self.draft.entries.firstIndex(where: { $0.id == entry.id }) else { return }
                    self.draft.entries[index].note = value
                }))
        }
        return settings
    }
}
