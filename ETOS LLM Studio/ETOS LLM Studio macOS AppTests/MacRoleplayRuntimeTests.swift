import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

@MainActor
struct MacRoleplayRuntimeTests {
    @Test("切换会话撤销旧 HTML，保留仍在生成的脚本；恢复后重新装载网页")
    func endpointsFollowSourceAndLifecycle() {
        let runtime = MacRoleplayRuntime(), workspace = MacWorkspaceModel()
        let first = UUID(), second = UUID()
        let html = document(sessionID: first)
        let script = document(sessionID: first, scriptID: UUID())
        let next = document(sessionID: second, scriptID: UUID())
        let row = MacMessagePresentation.prepare(.init(role: .assistant, content: ""), markdown: false, roleplayDocuments: [html])
        let presentation = MacRoleplayPresentation(rows: [row], scripts: [script, next], buttons: [])
        runtime.apply(presentation, workspace: workspace)
        let htmlEndpoint = RoleplayEndpointFixture(), scriptEndpoint = RoleplayEndpointFixture()
        let htmlOwner = UUID(), scriptOwner = UUID()
        runtime.register(htmlEndpoint, owner: htmlOwner, documentID: html.id)
        runtime.register(scriptEndpoint, owner: scriptOwner, documentID: script.id)
        #expect(runtime.isActive(owner: htmlOwner, documentID: html.id))
        runtime.showSession(second, running: [first])
        #expect(!runtime.isActive(owner: htmlOwner, documentID: html.id))
        #expect(htmlEndpoint.invalidations == 1)
        #expect(runtime.isActive(owner: scriptOwner, documentID: script.id))
        runtime.suspend()
        let suspendedEpoch = runtime.epoch
        #expect(scriptEndpoint.invalidations == 1)
        #expect(runtime.scripts.isEmpty)
        runtime.resume()
        runtime.apply(presentation, workspace: workspace)
        #expect(runtime.epoch != suspendedEpoch)
        let replacement = RoleplayEndpointFixture(), owner = UUID()
        runtime.register(replacement, owner: owner, documentID: html.id)
        #expect(runtime.isActive(owner: owner, documentID: html.id))
        runtime.suspend()
    }

    @Test("网页移除后仍等待不配合取消的任务完成", .timeLimit(.minutes(1)))
    func removedEndpointDoesNotLosePendingWrite() async {
        let runtime = MacRoleplayRuntime()
        let gate = MacRoleplayWriteGate()
        let (started, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish() }
        var finished = false
        let task = Task {
            signal.yield(())
            await gate.wait()
            finished = true
        }
        let owner = UUID()
        runtime.track(task, owner: owner)
        var events = started.makeAsyncIterator()
        _ = await events.next()
        runtime.unregister(owner)
        runtime.suspend()
        #expect(runtime.isBusy)
        #expect(!finished)
        await gate.release()
        await runtime.waitForPendingActions()
        #expect(finished)
    }

    @Test("外链不能替换有原生权限的主文档，其他本地文件和自定义协议被拒绝")
    func navigationKeepsBridgeInLocalDocument() throws {
        let base = URL(fileURLWithPath: "/tmp/ELS/images/")
        let remote = try #require(URL(string: "https://example.com/page"))
        #expect(MacRoleplayNavigationPolicy.decision(url: remote, isLink: false, isMainFrame: true, baseURL: base) == .cancel)
        #expect(MacRoleplayNavigationPolicy.decision(url: remote, isLink: true, isMainFrame: true, baseURL: base) == .external)
        #expect(MacRoleplayNavigationPolicy.decision(url: remote, isLink: false, isMainFrame: false, baseURL: base) == .allow)
        #expect(MacRoleplayNavigationPolicy.decision(url: base, isLink: false, isMainFrame: true, baseURL: base) == .allow)
        #expect(MacRoleplayNavigationPolicy.decision(url: URL(fileURLWithPath: "/tmp/private.txt"), isLink: true, isMainFrame: true, baseURL: base) == .cancel)
        let command = try #require(URL(string: "shortcuts://run-shortcut?name=test"))
        #expect(MacRoleplayNavigationPolicy.decision(url: command, isLink: true, isMainFrame: false, baseURL: base) == .cancel)
    }

    @Test("网页通知参数作为 JSON 字面量编码")
    func notificationArgumentsAreEncoded() throws {
        let text = "引号\"、换行\n和 ); alert('x');"
        let source = try #require(MacRoleplayJavaScriptCall(function: "__etosEmitScriptButton", arguments: [text]).source())
        let prefix = "window.__etosEmitScriptButton?.(..."
        #expect(source.hasPrefix(prefix))
        let literal = String(source.dropFirst(prefix.count).dropLast(2))
        #expect(try JSONDecoder().decode([String].self, from: Data(literal.utf8)) == [text])
    }

    private func document(sessionID: UUID, scriptID: UUID? = nil) -> RoleplayPreparedDocument {
        RoleplayPreparedDocument(id: UUID().uuidString, sessionID: sessionID, messageID: UUID(), versionIndex: 0,
                                 scriptID: scriptID, title: "测试", source: "", html: "", variableUpdate: "", variableRevision: 0,
                                 baseURL: URL(fileURLWithPath: "/tmp/ELS/images/"),
                                 bridgeSource: .init(sessionID: sessionID, binding: nil, characters: [], messages: []))
    }
}

@MainActor
private final class RoleplayEndpointFixture: MacRoleplayEndpoint {
    private(set) var invalidations = 0
    func invalidate() { invalidations += 1 }
}

private actor MacRoleplayWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
