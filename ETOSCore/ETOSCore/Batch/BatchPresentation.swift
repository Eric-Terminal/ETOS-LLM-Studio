import Foundation
import Combine

public struct BatchModelOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let providerID: String
    public let providerName: String
    public let name: String
    public let modelName: String
    public var title: String { "\(providerName) · \(name)" }
}

struct BatchResultRow: Identifiable, Sendable {
    let id: String
    let input: String
    let preview: String
    let text: String
    let reasoning: String?
    let error: String?
    let isPending: Bool
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
                text: result?.text ?? "", reasoning: result?.reasoning, error: result?.error, isPending: result == nil)
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
            models: models().map { BatchModelOption(id: $0.id, providerID: $0.provider.id.uuidString,
                providerName: $0.provider.name, name: $0.model.displayName, modelName: $0.model.modelName) })
    }
}

@MainActor
final class BatchTasksModel: ObservableObject {
    @Published var snapshot = BatchPresentation()
    @Published var error: String?
    @Published var busy = false
    @Published var exportURL: URL?
    @Published var exportJobID: UUID?
    @Published var submissionReport: BatchSubmissionReport?
    private var loadRevision = UUID()

    var submissionNotice: String? { submissionReport?.notice }

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
