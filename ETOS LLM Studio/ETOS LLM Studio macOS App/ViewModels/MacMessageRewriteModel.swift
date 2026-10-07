import Combine
import ETOSCore
import Foundation

struct MacRewriteReferenceRow: Identifiable, Sendable {
    let version: MessageRewriteReferenceVersion
    let preview: String
    var id: Int { version.id }
}

struct MacMessageRewriteRequest: Sendable {
    let message: ChatMessage
    let sessionID: UUID
    let instruction: String
    let references: [MessageRewriteReferenceVersion]
    let selection: MessageRewriteSelectionTarget?
}

@MainActor
final class MacMessageRewriteModel: ObservableObject {
    let target: MacMessageEditTarget
    @Published var instruction = ""
    @Published var selectionOnly = false
    @Published private(set) var references: [MacRewriteReferenceRow] = []
    @Published private(set) var selectedReferenceIDs: Set<Int> = []
    @Published private(set) var document: MessageSelectableTextDocument?
    @Published private(set) var documentID = UUID()
    @Published private(set) var selection: MessageRewriteSelectionTarget?
    @Published private(set) var isPreparing = true
    @Published private(set) var isPreparingSelection = false
    @Published var error: String?
    private var selectionTask: Task<Void, Never>?

    init(target: MacMessageEditTarget) { self.target = target }

    func load(using service: ChatService?) async {
        isPreparing = true
        defer { isPreparing = false }
        guard let service else { return }
        let target = target
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                let messages = service.messagesSnapshot(for: target.sessionID)
                guard messages.first(where: { $0.id == target.message.id }) == target.message else { throw MessageToolCallEditingError.messageChanged }
                let document = MessageTextSelectionSupport.selectableDocument(fromMarkdown: target.message.content)
                let references = MessageRewriteReferenceSupport.referenceVersions(for: target.message, in: messages).map {
                    MacRewriteReferenceRow(version: $0, preview: String($0.content.prefix(240)))
                }
                return (document, references)
            }.value
            guard !Task.isCancelled else { return }
            document = prepared.0
            references = prepared.1
            selection = nil
            documentID = UUID()
        } catch { self.error = error.localizedDescription }
    }

    func toggleReference(_ id: Int, enabled: Bool) {
        if enabled { selectedReferenceIDs.insert(id) }
        else { selectedReferenceIDs.remove(id) }
    }

    func updateSelection(_ range: NSRange) {
        selectionTask?.cancel()
        selection = nil
        guard let document, range.location != NSNotFound, range.length > 0 else { isPreparingSelection = false; return }
        isPreparingSelection = true
        selectionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            let selected = await Task.detached(priority: .userInitiated) {
                document.rewriteTarget(displayUTF16Range: range.location..<(range.location + range.length))
            }.value
            guard let self, !Task.isCancelled else { return }
            selection = selected
            isPreparingSelection = false
        }
    }

    func prepareRequest() async throws -> MacMessageRewriteRequest {
        let target = target
        let instruction = instruction
        let references = references
        let selectedIDs = selectedReferenceIDs
        let selection = selectionOnly ? selection : nil
        guard !isPreparing, document != nil, !selectionOnly || selection != nil else { throw ChatService.MessageRewriteError.selectionOutdated }
        return try await Task.detached(priority: .userInitiated) {
            guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatService.MessageRewriteError.emptyInstruction }
            return MacMessageRewriteRequest(message: target.message, sessionID: target.sessionID, instruction: instruction,
                                           references: selection == nil ? references.filter { selectedIDs.contains($0.id) }.map(\.version) : [], selection: selection)
        }.value
    }
}
