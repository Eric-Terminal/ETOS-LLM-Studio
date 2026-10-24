import Foundation
import Combine

struct BatchDraftRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let preview: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
        preview = String(text.prefix(160))
    }
}

struct BatchModelGroup: Identifiable, Sendable {
    let id: String
    let name: String
    let models: [BatchModelOption]
}

/// 搜索、分组和提交摘要一起预计算；视图不在每次绘制时扫描整个模型库。
struct BatchDraftSnapshot: Sendable {
    var groups: [BatchModelGroup] = []
    var providers: [BatchModelGroup] = []
    var visibleIDs = Set<String>()
    var selectedIDs = Set<String>()
    var selectedModels: [BatchModelOption] = []
    var inputs: [String] = []
    var summary = ""
    var modelSummary = ""
    var selectionSummary = ""
    var totalSummary = ""
    var selectedNames = ""
    var providerChoices = ""
    var allVisibleSelected = false
    var canSubmit = false

    static func make(requests: [BatchDraftRequest], models: [BatchModelOption], selectedIDs: Set<String>,
                     search: String, providerID: String, selectedOnly: Bool) -> Self {
        var snapshot = Self()
        snapshot.inputs = requests.map(\.text)
        snapshot.selectedModels = models.filter { selectedIDs.contains($0.id) }
        snapshot.selectedIDs = Set(snapshot.selectedModels.map(\.id))
        snapshot.selectedNames = snapshot.selectedModels.map(\.title).joined(separator: "\n")
        let grouped = Dictionary(grouping: models, by: \.providerID)
        snapshot.providers = grouped.map { id, options in
            BatchModelGroup(id: id, name: options[0].providerName, models: options)
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        snapshot.providerChoices = snapshot.providers.map { "\($0.id): \($0.name)" }.joined(separator: "\n")
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.groups = snapshot.providers.compactMap { group in
            guard providerID.isEmpty || group.id == providerID else { return nil }
            let visible = group.models.filter {
                (!selectedOnly || selectedIDs.contains($0.id)) &&
                (query.isEmpty || $0.name.localizedStandardContains(query) || $0.modelName.localizedStandardContains(query)
                 || $0.providerName.localizedStandardContains(query))
            }
            return visible.isEmpty ? nil : BatchModelGroup(id: group.id, name: group.name, models: visible)
        }
        snapshot.visibleIDs = Set(snapshot.groups.flatMap { $0.models.map(\.id) })
        snapshot.allVisibleSelected = !snapshot.visibleIDs.isEmpty && snapshot.visibleIDs.isSubset(of: snapshot.selectedIDs)
        let count = snapshot.selectedModels.count
        snapshot.summary = String(format: NSLocalizedString("batch.draft.count", value: "%d requests × %d models", comment: ""), requests.count, count)
        snapshot.totalSummary = String(format: NSLocalizedString("batch.review.total", value: "%d requests in total · %d remote tasks", comment: "提交总量"), requests.count * count, count)
        snapshot.modelSummary = count == 1 ? snapshot.selectedModels[0].title : String(format:
            NSLocalizedString("batch.models.selected", value: "%d models selected", comment: "已选模型数量"), count)
        snapshot.selectionSummary = String(format: NSLocalizedString("batch.models.count", value: "%d shown · %d selected", comment: "筛选与选择数量"), snapshot.visibleIDs.count, count)
        snapshot.canSubmit = !requests.isEmpty && count > 0 && requests.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return snapshot
    }
}

@MainActor
final class BatchDraftModel: ObservableObject {
    @Published var title = ""
    @Published var search = "" { didSet { rebuild() } }
    @Published var providerID = "" { didSet { rebuild() } }
    @Published var selectedOnly = false { didSet { rebuild() } }
    @Published private(set) var requests: [BatchDraftRequest] = []
    @Published private(set) var selectedIDs = Set<String>()
    @Published private(set) var snapshot = BatchDraftSnapshot()
    @Published private(set) var isUpdating = false
    @Published private(set) var guideSettings: [GuidePageSetting] = []
    @Published private(set) var pickerGuideSettings: [GuidePageSetting] = []
    private var models: [BatchModelOption] = []
    private var update: Task<Void, Never>?

    var canSubmit: Bool { !isUpdating && snapshot.canSubmit }

    func configure(models: [BatchModelOption]) {
        self.models = models
        rebuild()
    }

    func saveRequest(id: UUID, text: String) async {
        let request = await Task.detached(priority: .userInitiated) {
            BatchDraftRequest(id: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
        guard !request.text.isEmpty else { return }
        if let index = requests.firstIndex(where: { $0.id == id }) { requests[index] = request }
        else { requests.append(request) }
        rebuild()
    }

    func appendLines(_ text: String) async {
        let added = await Task.detached(priority: .userInitiated) {
            text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { BatchDraftRequest(text: $0) }
        }.value
        requests.append(contentsOf: added)
        rebuild()
    }

    func removeRequests(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) { requests.remove(at: index) }
        rebuild()
    }

    func removeRequest(id: UUID) {
        requests.removeAll { $0.id == id }
        rebuild()
    }

    func select(_ id: String, selected: Bool) {
        if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        rebuild()
    }

    func selectVisible(_ selected: Bool) {
        // 搜索更新尚未完成时禁用批量操作，防止把上一个筛选结果误当成当前范围。
        guard !isUpdating else { return }
        if selected { selectedIDs.formUnion(snapshot.visibleIDs) }
        else { selectedIDs.subtract(snapshot.visibleIDs) }
        rebuild()
    }

    func waitForUpdates() async {
        while isUpdating { await update?.value }
    }

    private func rebuild() {
        update?.cancel()
        isUpdating = true
        let requests = self.requests, models = self.models, selected = selectedIDs
        let search = self.search, providerID = self.providerID, selectedOnly = self.selectedOnly
        update = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                BatchDraftSnapshot.make(requests: requests, models: models, selectedIDs: selected,
                                        search: search, providerID: providerID, selectedOnly: selectedOnly)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.snapshot = snapshot
            self.selectedIDs = snapshot.selectedIDs
            self.isUpdating = false
            self.configureGuide()
            if !providerID.isEmpty, !snapshot.providers.contains(where: { $0.id == providerID }) {
                self.providerID = ""
            }
        }
    }

    private func configureGuide() {
        let draftNotice = GuidePageSetting.readOnly("draft_only", label:
            NSLocalizedString("batch.draft.notice", value: "Changes affect this draft only. Submit manually to send requests.", comment: ""), value: { .bool(true) })
        guideSettings = [
            .string("title", label: NSLocalizedString("batch.name", value: "Name", comment: ""),
                    get: { [weak self] in self?.title ?? "" }, set: { [weak self] in self?.title = $0 }),
            .readOnly("request_count", label: NSLocalizedString("batch.requests", value: "Requests", comment: ""),
                      value: { [weak self] in .int(self?.requests.count ?? 0) }),
            .readOnly("models", label: NSLocalizedString("batch.models", value: "Models", comment: ""),
                      value: { [weak self] in .string(self?.snapshot.selectedNames ?? "") }), draftNotice
        ]
        pickerGuideSettings = [
            .string("search", label: NSLocalizedString("batch.models.search", value: "Search models or providers", comment: ""),
                    get: { [weak self] in self?.search ?? "" }, set: { [weak self] in self?.search = $0 }),
            .bool("selected_only", label: NSLocalizedString("batch.models.selectedOnly", value: "Selected Only", comment: ""),
                  get: { [weak self] in self?.selectedOnly ?? false }, set: { [weak self] in self?.selectedOnly = $0 }),
            .string("provider_filter", label: NSLocalizedString("batch.models.provider", value: "Provider", comment: ""),
                    allowedValues: [""] + snapshot.providers.map(\.id),
                    get: { [weak self] in self?.providerID ?? "" }, set: { [weak self] in self?.providerID = $0 }),
            .readOnly("providers", label: NSLocalizedString("batch.models.providerOptions", value: "Available Providers", comment: ""),
                      value: { [weak self] in .string(self?.snapshot.providerChoices ?? "") }),
            .readOnly("selection", label: NSLocalizedString("batch.models", value: "Models", comment: ""),
                      value: { [weak self] in .string(self?.snapshot.selectedNames ?? "") }), draftNotice
        ] + snapshot.groups.flatMap(\.models).map { option in
            .bool("model_" + option.id, label: option.title,
                  get: { [weak self] in self?.selectedIDs.contains(option.id) == true },
                  set: { [weak self] in self?.select(option.id, selected: $0) })
        }
    }
}

@MainActor
final class BatchRequestEditorModel: ObservableObject {
    @Published var text: String { didSet { validate() } }
    @Published private(set) var canSave = false
    @Published private(set) var hasChanges = false
    @Published private(set) var countSummary = ""
    private let originalText: String
    private let splitsLines: Bool
    private var validation: Task<Void, Never>?

    init(text: String, splitsLines: Bool = false) {
        self.text = text
        originalText = text
        self.splitsLines = splitsLines
        validate()
    }

    func refreshLanguage() { validate() }

    private func validate() {
        validation?.cancel()
        canSave = false
        let text = self.text, original = originalText, splitsLines = self.splitsLines
        validation = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let count = splitsLines
                    ? text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                    : (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
                let summary = String(format: NSLocalizedString("batch.requests.count", value: "%d requests", comment: "请求数量"), count)
                return (count > 0, text != original, summary)
            }.value
            guard !Task.isCancelled else { return }
            self?.canSave = result.0
            self?.hasChanges = result.1
            self?.countSummary = result.2
        }
    }
}
