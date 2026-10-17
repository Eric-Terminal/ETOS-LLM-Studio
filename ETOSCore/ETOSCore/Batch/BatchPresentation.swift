import Foundation
import Combine

public struct BatchModelOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
}

struct BatchResultRow: Identifiable, Sendable {
    let id: String
    let input: String
    let preview: String
    let text: String
    let reasoning: String?
    let error: String?
}

struct BatchJobRow: Identifiable, Sendable {
    let id: UUID
    let title: String
    let model: String
    let status: String
    let progress: String
    let createdAt: Date
    let remoteID: String?
    let error: String?
    let results: [BatchResultRow]
    let resultsByID: [String: BatchResultRow]
    let canCancel: Bool
    let canRetry: Bool
    let canResume: Bool
    let canRemove: Bool
    let canExport: Bool

    init(job: BatchJob) {
        id = job.id
        title = job.title.isEmpty ? job.modelName : job.title
        model = "\(job.providerName) · \(job.modelName)"
        status = Self.statusTitle(job)
        let successes = job.results.filter(\.succeeded).count
        let failures = job.results.count - successes
        progress = String(format: NSLocalizedString("batch.progress", value: "%d requests · %d succeeded · %d failed", comment: "批量任务计数"),
                          job.requests.count, successes, failures)
        createdAt = job.remoteCreatedAt ?? job.createdAt
        remoteID = job.remoteID
        error = job.errorMessage
        let byID = Dictionary(uniqueKeysWithValues: job.results.map { ($0.id, $0) })
        results = job.requests.map { request in
            let result = byID[request.id]
            return BatchResultRow(id: request.id, input: request.input, preview: String(request.input.prefix(100)),
                text: result?.text ?? "", reasoning: result?.reasoning, error: result?.error)
        }
        resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        canCancel = job.remoteID != nil && job.status?.isTerminal != true && job.status != .cancelling
        canRetry = job.resultsDownloaded && failures > 0
        canResume = job.remoteID == nil
        canRemove = job.status?.isTerminal == true || (job.remoteID == nil && ![.creating, .uncertain].contains(job.submission))
        canExport = job.resultsDownloaded
    }

    static func statusTitle(_ job: BatchJob) -> String {
        if let status = job.status {
            switch status {
            case .validating: return NSLocalizedString("batch.status.validating", value: "Validating", comment: "批量状态")
            case .inProgress: return NSLocalizedString("batch.status.running", value: "In progress", comment: "批量状态")
            case .finalizing: return NSLocalizedString("batch.status.finalizing", value: "Preparing results", comment: "批量状态")
            case .completed: return NSLocalizedString("batch.status.completed", value: "Completed", comment: "批量状态")
            case .failed: return NSLocalizedString("batch.status.failed", value: "Failed", comment: "批量状态")
            case .expired: return NSLocalizedString("batch.status.expired", value: "Expired", comment: "批量状态")
            case .cancelling: return NSLocalizedString("batch.status.cancelling", value: "Cancelling", comment: "批量状态")
            case .cancelled: return NSLocalizedString("batch.status.cancelled", value: "Cancelled", comment: "批量状态")
            }
        }
        switch job.submission {
        case .prepared: return NSLocalizedString("batch.status.prepared", value: "Ready to submit", comment: "批量状态")
        case .uploading: return NSLocalizedString("batch.status.uploading", value: "Uploading", comment: "批量状态")
        case .creating: return NSLocalizedString("batch.status.creating", value: "Submitting", comment: "批量状态")
        case .uncertain: return NSLocalizedString("batch.status.uncertain", value: "Submission needs verification", comment: "批量状态")
        case .failed: return NSLocalizedString("batch.status.failed", value: "Failed", comment: "批量状态")
        case .submitted: return NSLocalizedString("batch.status.running", value: "In progress", comment: "批量状态")
        }
    }
}

struct BatchPresentation: Sendable {
    var jobs: [BatchJobRow] = []
    var byID: [UUID: BatchJobRow] = [:]
    var models: [BatchModelOption] = []
}

extension BatchService {
    func presentation() throws -> BatchPresentation {
        let rows = try jobs().map(BatchJobRow.init)
        return BatchPresentation(jobs: rows, byID: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }),
            models: models().map { BatchModelOption(id: $0.id, title: "\($0.provider.name) · \($0.model.displayName)") })
    }
}

@MainActor
final class BatchTasksModel: ObservableObject {
    @Published var snapshot = BatchPresentation()
    @Published var error: String?
    @Published var busy = false
    @Published var exportURL: URL?
    @Published var exportJobID: UUID?
    private var loadRevision = UUID()

    func reload() async {
        let revision = UUID()
        loadRevision = revision
        do {
            let snapshot = try await BatchService.shared.presentation()
            guard revision == loadRevision else { return }
            self.snapshot = snapshot
        } catch { self.error = error.localizedDescription }
    }

    func perform(_ operation: @escaping @Sendable () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await operation() }
        catch { self.error = error.localizedDescription }
        await reload()
    }

    func export(id: UUID) async {
        do {
            let url = try await BatchService.shared.export(id: id)
            exportJobID = id
            exportURL = url
        }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
final class BatchDraftModel: ObservableObject {
    @Published var title = ""
    @Published var nextInput = ""
    @Published var inputText = "" { didSet { validate() } }
    @Published var selectedIDs = Set<String>() { didSet { validate() } }
    @Published private(set) var inputs: [String] = []
    @Published private(set) var canSubmit = false
    @Published private(set) var summary = ""
    @Published private(set) var guideSettings: [GuidePageSetting] = []
    private var validation: Task<Void, Never>?

    func configure(models: [BatchModelOption]) {
        guideSettings = [
            .string("title", label: NSLocalizedString("batch.name", value: "Name", comment: "批量草稿名称"),
                    get: { [weak self] in self?.title ?? "" }, set: { [weak self] in self?.title = $0 }),
            .string("requests", label: NSLocalizedString("batch.requests", value: "Requests", comment: "批量草稿输入"),
                    get: { [weak self] in self?.inputText ?? "" }, set: { [weak self] in self?.inputText = $0 }),
            .readOnly("draft_only", label: NSLocalizedString("batch.draft.notice", value: "Changes affect this draft only. Submit manually to send requests.", comment: "批量向导草稿说明"), value: { .bool(true) })
        ] + models.map { option in
            .bool("model_" + option.id, label: option.title,
                  get: { [weak self] in self?.selectedIDs.contains(option.id) == true },
                  set: { [weak self] selected in
                      if selected { self?.selectedIDs.insert(option.id) }
                      else { self?.selectedIDs.remove(option.id) }
                  })
        }
        #if os(watchOS)
        guideSettings.append(.string("next_request", label: NSLocalizedString("batch.input", value: "Input", comment: "批量原始输入"),
            get: { [weak self] in self?.nextInput ?? "" }, set: { [weak self] in self?.nextInput = $0 }))
        #endif
        validate()
    }

    func appendInput() {
        inputText += (inputText.isEmpty ? "" : "\n") + nextInput
        nextInput = ""
    }

    func removeInputs(at indices: IndexSet) {
        inputText = inputs.enumerated().filter { !indices.contains($0.offset) }.map(\.element).joined(separator: "\n")
    }

    private func validate() {
        validation?.cancel()
        canSubmit = false
        let text = inputText
        let count = selectedIDs.count
        validation = Task { [weak self] in
            let inputs = await Task.detached(priority: .userInitiated) {
                text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.inputs = inputs
            self.canSubmit = !inputs.isEmpty && count > 0
            self.summary = String(format: NSLocalizedString("batch.draft.count", value: "%d requests × %d models", comment: "批量草稿数量"), inputs.count, count)
        }
    }
}
