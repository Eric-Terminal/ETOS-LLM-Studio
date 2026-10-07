import Combine
import ETOSCore
import Foundation

@MainActor
final class MacRequestParameterModel: ObservableObject {
    @Published var draft = MacRequestParameterDraft() { didSet { refresh() } }
    @Published private(set) var preview = ""
    @Published private(set) var error: String?
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    private(set) var revision = UUID()
    private var preparation: Task<Void, Never>?
    private(set) var parameters: [String: JSONValue]?

    func load(parameters: [String: JSONValue], mode: Model.RequestBodyOverrideMode, rawJSON: String?) async {
        guard !ready else { return }
        let value = await Task.detached { MacRequestParameterDraft(parameters: parameters, mode: mode, rawJSON: rawJSON) }.value
        guard !Task.isCancelled else { return }
        draft = value
        ready = true
        await preparation?.value
    }

    func refresh() {
        preparation?.cancel()
        revision = UUID()
        let token = revision, source = draft
        parameters = nil
        preview = ""
        busy = true
        preparation = Task { [weak self] in
            let result = await Task.detached { () -> Result<([String: JSONValue], String), Error> in
                Result {
                    let values = try source.parameters()
                    return (values, ParameterExpressionParser.serializeRawJSONObject(parameters: values))
                }
            }.value
            guard let self, !Task.isCancelled, revision == token else { return }
            busy = false
            switch result {
            case .success(let value): parameters = value.0; preview = value.1; error = nil
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    func changeMode(_ mode: Model.RequestBodyOverrideMode) async {
        guard ready, !busy, mode != draft.mode else { return }
        let source = draft, token = revision
        busy = true
        do {
            let converted = try await Task.detached { try source.converted(to: mode) }.value
            guard !Task.isCancelled, token == revision else { if token == revision { busy = false }; return }
            draft = converted
        } catch { if token == revision { busy = false; error = error.localizedDescription } }
    }

    func replace(with values: [String: JSONValue]?, mode: Model.RequestBodyOverrideMode? = nil, expectedRevision: UUID) async throws {
        guard ready, !busy, revision == expectedRevision else { throw GuideError.pageChanged }
        let source = draft, mode = mode ?? draft.mode
        let replacement = try await Task.detached {
            let values = try values ?? source.parameters()
            return try MacRequestParameterDraft(parameters: values, mode: .rawJSON).converted(to: mode)
        }.value
        guard !Task.isCancelled, revision == expectedRevision else { throw GuideError.pageChanged }
        draft = replacement
    }

    func cancel() { preparation?.cancel(); revision = UUID() }
}
