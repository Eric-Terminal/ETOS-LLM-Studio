import AppKit
import Combine
import ETOSCore

@MainActor
final class MacApplicationDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var isTerminating = false
    private var terminationTask: Task<Void, Never>?
    weak var workspace: MacWorkspaceModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        isTerminating = true
        // terminateLater 保持事件循环运转，不能在主线程同步等待管道或子进程退出。
        terminationTask = Task {
            await workspace?.prepareForTermination()
            await MCPMacStdioTransport.prepareForApplicationTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
