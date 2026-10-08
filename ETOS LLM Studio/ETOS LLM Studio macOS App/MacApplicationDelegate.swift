import AppKit
import Combine
import ETOSCore

@MainActor
final class MacApplicationDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var isTerminating = false
    private var terminationTask: Task<Void, Never>?
    private weak var workspace: MacWorkspaceModel?
    private var pendingOpenRequests: [[URL]] = []
    private var showWorkspace: (@MainActor () -> Void)?
    private var openTasks: [UUID: Task<Void, Never>] = [:]
    private var pulseNotifications: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppLocalNotificationCenter.shared.configureIfNeeded()
        pulseNotifications = AppLocalNotificationCenter.shared.$pendingDailyPulseRequests.receive(on: DispatchQueue.main)
            .sink { [weak self] requests in
                guard !requests.isEmpty, let self, !isTerminating else { return }
                showWorkspace?()
            }
    }

    func attach(workspace: MacWorkspaceModel, showWorkspace: @escaping @MainActor () -> Void) {
        self.workspace = workspace; self.showWorkspace = showWorkspace
        if !isTerminating, !AppLocalNotificationCenter.shared.pendingDailyPulseRequests.isEmpty { showWorkspace() }
        guard !isTerminating, !pendingOpenRequests.isEmpty else { return }
        let pending = pendingOpenRequests
        pendingOpenRequests.removeAll()
        showWorkspace()
        for urls in pending { receive(urls, workspace: workspace) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isTerminating else { return }
        // 保留 Finder 的批次边界，权重和 mmproj 才能一次配对导入。
        guard let workspace else { pendingOpenRequests.append(urls); return }
        showWorkspace?()
        receive(urls, workspace: workspace)
    }

    private func receive(_ urls: [URL], workspace: MacWorkspaceModel) {
        let token = UUID()
        let revision = workspace.externalOpenRevision
        let attachmentContext = workspace.phase == .ready ? workspace.incomingDocuments.contextID : nil
        openTasks[token] = Task { [weak self, weak workspace] in
            let selection = await Task.detached(priority: .userInitiated) { MacExternalOpenSelection(urls: urls) }.value
            defer { self?.openTasks.removeValue(forKey: token) }
            guard let self, !isTerminating, !Task.isCancelled, let workspace else { return }
            // 冷启动允许等待工作区就绪；已打开的会话与数据库切换后拒绝迟到附件。
            guard revision == workspace.externalOpenRevision else { return }
            if !selection.files.isEmpty, attachmentContext == nil || attachmentContext == workspace.incomingDocuments.contextID {
                workspace.receiveDocuments(selection.files)
            }
            if workspace.phase == .ready && !workspace.isRestoringData {
                // 只接收已启动调用的结果；锁定不应使已有请求永远等待回调。
                for url in selection.shortcutCompletions { ShortcutToolManager.handleCompletionIfInitialized(url) }
            }
            if selection.hasUnsupportedURLs { workspace.errorMessage = MacIncomingDocumentError.localFilesOnly.localizedDescription }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        isTerminating = true
        pendingOpenRequests.removeAll()
        for task in openTasks.values { task.cancel() }
        openTasks.removeAll()
        // terminateLater 保持事件循环运转，不能在主线程同步等待管道或子进程退出。
        terminationTask = Task {
            await workspace?.prepareForTermination()
            await MCPMacStdioTransport.prepareForApplicationTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
