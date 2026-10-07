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

    func attach(workspace: MacWorkspaceModel, showWorkspace: @escaping @MainActor () -> Void) {
        self.workspace = workspace; self.showWorkspace = showWorkspace
        guard !isTerminating, !pendingOpenRequests.isEmpty else { return }
        let pending = pendingOpenRequests
        pendingOpenRequests.removeAll()
        showWorkspace()
        for urls in pending { workspace.receiveDocuments(urls) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isTerminating else { return }
        // 保留 Finder 的批次边界，权重和 mmproj 才能一次配对导入。
        guard let workspace else { pendingOpenRequests.append(urls); return }
        showWorkspace?()
        workspace.receiveDocuments(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        isTerminating = true
        pendingOpenRequests.removeAll()
        // terminateLater 保持事件循环运转，不能在主线程同步等待管道或子进程退出。
        terminationTask = Task {
            await workspace?.prepareForTermination()
            await MCPMacStdioTransport.prepareForApplicationTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
