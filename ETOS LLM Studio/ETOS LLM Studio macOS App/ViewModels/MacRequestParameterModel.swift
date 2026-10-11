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
    @Published private(set) var isShowingSuggestion = false
    private(set) var hasConsumedSuggestion = false
    private(set) var revision = UUID()
    private var preparation: Task<Void, Never>?
    private(set) var parameters: [String: JSONValue]?
    private var suggestedParameters: [String: JSONValue]?
    private var suggestionBaseline: MacRequestParameterDraft?

    func load(parameters: [String: JSONValue], mode: Model.RequestBodyOverrideMode, rawJSON: String?, suggestion: [String: JSONValue]? = nil) async {
        guard !ready else { return }
        let suggestion = parameters.isEmpty ? suggestion : nil
        let value = await Task.detached {
            if let suggestion, !suggestion.isEmpty { return MacRequestParameterDraft.suggestion(parameters: suggestion, mode: mode) }
            return MacRequestParameterDraft(parameters: parameters, mode: mode, rawJSON: rawJSON)
        }.value
        guard !Task.isCancelled else { return }
        suggestedParameters = suggestion
        if let suggestion, !suggestion.isEmpty { suggestionBaseline = value }
        draft = value
        ready = true
        await preparation?.value
    }

    func refresh() {
        preparation?.cancel()
        revision = UUID()
        let token = revision, source = draft, baseline = suggestionBaseline
        parameters = nil
        preview = ""
        busy = true
        preparation = Task { [weak self] in
            let prepared = await Task.detached {
                let isSuggestion = baseline == source
                let result = Result { () -> ([String: JSONValue], String) in
                    let values: [String: JSONValue]
                    if isSuggestion { values = [:] } else { values = try source.parameters() }
                    return (values, ParameterExpressionParser.serializeRawJSONObject(parameters: values))
                }
                return (isSuggestion, result)
            }.value
            guard let self, !Task.isCancelled, revision == token else { return }
            isShowingSuggestion = prepared.0
            if baseline != nil, !prepared.0 {
                suggestionBaseline = nil; suggestedParameters = nil; hasConsumedSuggestion = true
            }
            busy = false
            switch prepared.1 {
            case .success(let value): parameters = value.0; preview = value.1; error = nil
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    func changeMode(_ mode: Model.RequestBodyOverrideMode) async {
        guard ready, !busy, mode != draft.mode else { return }
        let source = draft, token = revision, suggestion = isShowingSuggestion ? suggestedParameters : nil
        busy = true
        do {
            let converted = try await Task.detached {
                if let suggestion {
                    let value = MacRequestParameterDraft.suggestion(parameters: suggestion, mode: mode)
                    guard value.mode == mode else { throw MacRequestParameterError.lossyConversion }
                    return value
                }
                return try source.converted(to: mode)
            }.value
            guard !Task.isCancelled, token == revision else { if token == revision { busy = false }; return }
            if suggestion != nil { suggestionBaseline = converted }
            draft = converted
            await preparation?.value
        } catch { if token == revision { busy = false; self.error = error.localizedDescription } }
    }

    func replace(with values: [String: JSONValue]?, mode: Model.RequestBodyOverrideMode? = nil, expectedRevision: UUID) async throws {
        guard ready, !busy, revision == expectedRevision else { throw GuideError.pageChanged }
        let source = draft, mode = mode ?? draft.mode
        let suggestion = values == nil && isShowingSuggestion ? suggestedParameters : nil
        let replacement = try await Task.detached {
            if let suggestion {
                let value = MacRequestParameterDraft.suggestion(parameters: suggestion, mode: mode)
                guard value.mode == mode else { throw MacRequestParameterError.lossyConversion }
                return value
            }
            let values = try values ?? source.parameters()
            return try MacRequestParameterDraft(parameters: values, mode: .rawJSON).converted(to: mode)
        }.value
        guard !Task.isCancelled, revision == expectedRevision else { throw GuideError.pageChanged }
        if suggestion != nil { suggestionBaseline = replacement }
        else if suggestionBaseline != nil {
            suggestionBaseline = nil; suggestedParameters = nil; hasConsumedSuggestion = true
        }
        draft = replacement
        await preparation?.value
    }

    func cancel() { preparation?.cancel(); revision = UUID() }
}
