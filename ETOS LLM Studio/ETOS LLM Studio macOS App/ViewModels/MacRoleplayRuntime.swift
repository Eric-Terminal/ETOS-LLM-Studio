import Combine
import ETOSCore
import Foundation

@MainActor
protocol MacRoleplayEndpoint: AnyObject {
    func invalidate()
}

/// 网页存活与已提交写入分开登记：移除网页不能让正在收尾的任务从恢复屏障中消失。
@MainActor
final class MacRoleplayRuntime: ObservableObject {
    @Published private(set) var scripts: [RoleplayPreparedDocument] = []
    @Published private(set) var buttons: [RoleplayPreparedButton] = []
    @Published private(set) var epoch = UUID()
    @Published private(set) var isBusy = false
    private weak var workspace: MacWorkspaceModel?
    private var accepting = true
    private var requiresRemount = false
    private var allowed = Set<String>()
    private var endpoints: [UUID: (documentID: String, endpoint: MacRoleplayEndpoint)] = [:]
    private var tasks: [UUID: (owner: UUID, task: Task<Void, Never>)] = [:]

    func apply(_ presentation: MacRoleplayPresentation, workspace: MacWorkspaceModel) {
        self.workspace = workspace
        guard accepting else { return }
        scripts = presentation.scripts
        buttons = presentation.buttons
        allowed = Set(presentation.rows.flatMap(\.roleplayDocuments).map(\.id) + scripts.map(\.id))
        if requiresRemount { requiresRemount = false; epoch = UUID() }
        for (id, registration) in Array(endpoints) where !allowed.contains(registration.documentID) {
            registration.endpoint.invalidate()
            unregister(id)
        }
    }

    func register(_ endpoint: MacRoleplayEndpoint, owner: UUID, documentID: String) {
        guard accepting, allowed.contains(documentID) else { endpoint.invalidate(); return }
        endpoints[owner] = (documentID, endpoint)
    }

    func isActive(owner: UUID, documentID: String) -> Bool {
        accepting && allowed.contains(documentID) && endpoints[owner]?.documentID == documentID
    }

    func unregister(_ owner: UUID) {
        endpoints.removeValue(forKey: owner)
        for operation in tasks.values where operation.owner == owner { operation.task.cancel() }
    }

    func handle(_ payload: [String: Any], owner: UUID, document: RoleplayPreparedDocument) {
        guard isActive(owner: owner, documentID: document.id), let action = payload["action"] as? String,
              let workspace, workspace.allowsRoleplayAction(action, sessionID: document.sessionID), let service = workspace.service else { return }
        let task: Task<Void, Never>
        if ["set_input", "send_message", "generate"].contains(action) {
            let previous = Array(tasks.values)
            let text = payload["text"] as? String ?? ""
            task = Task { [weak self, weak workspace] in
                for operation in previous { await operation.task.value }
                let valid = await Task.detached { document.bridgeSource.isCurrent(service: service) }.value
                guard valid else { return }
                guard !Task.isCancelled, self?.isActive(owner: owner, documentID: document.id) == true else { return }
                workspace?.handleRoleplayAction(action, text: text, sessionID: document.sessionID)
            }
        } else {
            task = RoleplayBridgeDispatcher.handle(payload, sessionID: document.sessionID, messageID: document.messageID,
                                                  versionIndex: document.versionIndex, service: service,
                                                  validateSource: {
                ["macro_expansion_response", "prompt_mutation_response"].contains(action) || document.bridgeSource.isCurrent(service: service)
            })
        }
        track(task, owner: owner)
    }

    func track(_ task: Task<Void, Never>, owner: UUID) {
        let id = UUID()
        tasks[id] = (owner, task)
        isBusy = true
        Task { [weak self] in
            await task.value
            self?.tasks.removeValue(forKey: id)
            self?.isBusy = self?.tasks.isEmpty == false
        }
    }

    func suspend() {
        accepting = false
        requiresRemount = true
        allowed.removeAll()
        for registration in endpoints.values { registration.endpoint.invalidate() }
        endpoints.removeAll()
        for operation in tasks.values { operation.task.cancel() }
        scripts = []
        buttons = []
        epoch = UUID()
    }

    func waitForPendingActions() async {
        let pending = Array(tasks.values)
        for operation in pending { await operation.task.value }
    }

    func resume() { accepting = true }

    func showSession(_ sessionID: UUID?, running: Set<UUID>) {
        scripts = scripts.filter { $0.sessionID == sessionID || running.contains($0.sessionID) }
        buttons = []
        allowed = Set(scripts.map(\.id))
        for (id, registration) in Array(endpoints) where !allowed.contains(registration.documentID) {
            registration.endpoint.invalidate()
            unregister(id)
        }
    }

    func press(_ button: RoleplayPreparedButton) {
        guard accepting, workspace?.currentSession?.id == button.sessionID else { return }
        NotificationCenter.default.post(name: RoleplayScriptButtonNotification.requested, object: nil, userInfo: [
            RoleplayScriptButtonNotification.sessionIDKey: button.sessionID,
            RoleplayScriptButtonNotification.scriptIDKey: button.scriptID,
            RoleplayScriptButtonNotification.buttonNameKey: button.name
        ])
    }
}
