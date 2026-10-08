import Combine
import ETOSCore
import Foundation

@MainActor
final class MacSlashCommandDraft: ObservableObject {
    @Published var trigger: String { didSet { validate() } }
    @Published var prompt: String { didSet { validate() } }
    @Published private(set) var replacement: [CustomChatSlashCommand]?
    @Published private(set) var validationMessage: String?
    @Published private(set) var isValidating = false
    private var validation: Task<Void, Never>?
    private var revision = UUID()
    let target: MacSlashCommandEditorTarget
    private let commandID: UUID

    init(target: MacSlashCommandEditorTarget) {
        self.target = target; commandID = target.command?.id ?? UUID()
        trigger = target.command?.trigger ?? ""; prompt = target.command?.prompt ?? ""
        validate()
    }

    func validate() {
        validation?.cancel(); revision = UUID(); replacement = nil; validationMessage = nil; isValidating = true
        let revision = revision, trigger = trigger, prompt = prompt, original = target.original, commandID = commandID
        validation = Task { [weak self] in
            let result = await Task.detached { () -> Result<[CustomChatSlashCommand], Error> in
                Result {
                    var commands = original.commands
                    let draft = CustomChatSlashCommand(id: commandID, trigger: trigger, prompt: prompt)
                    if let index = commands.firstIndex(where: { $0.id == commandID }) { commands[index] = draft }
                    else { commands.append(draft) }
                    return try CustomChatSlashCommandLibrary.validated(commands)
                }
            }.value
            guard let self, !Task.isCancelled, self.revision == revision else { return }
            isValidating = false
            switch result {
            case .success(let commands): replacement = commands
            case .failure(let error): validationMessage = error.localizedDescription
            }
        }
    }
}
