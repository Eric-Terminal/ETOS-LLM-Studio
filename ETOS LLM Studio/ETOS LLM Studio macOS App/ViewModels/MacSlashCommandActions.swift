import Combine
import ETOSCore
import Foundation

@MainActor
final class MacSlashCommandActions: ObservableObject {
    @Published private(set) var isWorking = false
    private var task: Task<Void, Never>?
    private var suspended = true
    private var epoch = UUID()

    func resume() { suspended = false; epoch = UUID() }
    func suspend() { suspended = true; epoch = UUID() }
    func waitForCompletion() async { await task?.value }

    func temporary(workspace: MacWorkspaceModel) {
        guard !suspended, workspace.canManageLocalModels,
              let service = workspace.service, let sessionID = workspace.currentSession?.id else { return }
        guard !isWorking, workspace.canModifyCurrentHistory else {
            workspace.errorMessage = MacMemoryWriteError.busy.localizedDescription; return
        }
        let expected = epoch, hasContinuation = workspace.contextCompression.presentation?.context != nil
        let preferred: TemporaryChatMemoryMode = AppConfigStore.shared.temporaryChatMemoryEnabled ? .enabled : .isolated
        workspace.incomingDocuments.invalidateAttachmentContext()
        isWorking = true
        task = Task { [weak self, weak workspace] in
            defer { self?.isWorking = false; self?.task = nil }
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    guard service.currentSessionSubject.value?.id == sessionID else { throw GuideError.pageChanged }
                    if let temporary = service.chatSessionsSubject.value.first(where: \.isTemporary),
                       service.runningSessionIDsSubject.value.contains(temporary.id) { throw MacMemoryWriteError.busy }
                    let canEnable = service.isTemporaryChatEnabled(for: sessionID)
                        || (service.messagesSnapshot(for: sessionID).isEmpty && !hasContinuation)
                    return service.performTemporaryChatTap(preferredMemoryMode: preferred, canEnable: canEnable)
                }.value
                // 轻点窗口与保存语义完全交给 Core；已经接受的操作在锁定或退出时也收尾。
                switch outcome {
                case .enabled(let mode), .memoryModeChanged(let mode): AppConfigStore.shared.temporaryChatMemoryEnabled = mode.isMemoryEnabled
                case .disabled: break
                case .unavailable:
                    if self?.epoch == expected { workspace?.errorMessage = NSLocalizedString("临时对话仅可在对话开始前开启。", comment: "") }
                }
                if self?.epoch == expected, self?.suspended == false {
                    workspace?.sessionLibrary.scope = .all; workspace?.sessionLibrary.query = ""
                }
            } catch { if self?.epoch == expected { workspace?.errorMessage = error.localizedDescription } }
        }
    }

    func retry(workspace: MacWorkspaceModel) {
        guard !suspended, workspace.canManageLocalModels,
              let service = workspace.service, let sessionID = workspace.currentSession?.id else { return }
        guard !isWorking, workspace.canModifyCurrentHistory else {
            workspace.errorMessage = MacMemoryWriteError.busy.localizedDescription; return
        }
        guard workspace.effectiveModelName != nil else {
            workspace.errorMessage = NSLocalizedString("请先激活一个聊天模型。", comment: ""); return
        }
        let expected = epoch
        isWorking = true
        task = Task { [weak self, weak workspace] in
            let latest = await Task.detached(priority: .userInitiated) { () -> ChatMessage? in
                let messages = service.messagesSnapshot(for: sessionID)
                guard ChatQuickRetrySupport.canRetryLatestMessage(in: messages, isSending: service.runningSessionIDsSubject.value.contains(sessionID)) else { return nil }
                return ChatResponseAttemptSupport.visibleMessages(from: messages).last
            }.value
            guard let self else { return }
            isWorking = false; task = nil
            guard !suspended, epoch == expected, let workspace, workspace.canManageLocalModels,
                  workspace.currentSession?.id == sessionID, service.currentSessionSubject.value?.id == sessionID else { return }
            guard let latest else {
                workspace.errorMessage = NSLocalizedString("当前没有可重试的回复。", comment: ""); return
            }
            workspace.retryMessage(latest)
        }
    }
}
