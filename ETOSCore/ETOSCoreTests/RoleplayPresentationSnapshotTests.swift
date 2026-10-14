import Foundation
import Testing
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
@testable import ETOSCore

@Suite("角色网页后台展示快照", .serialized)
struct RoleplayPresentationSnapshotTests {
    @Test("HTML 与脚本复用核心协议，变量更新不改变文档标识，消息编辑会改变标识")
    func documentIdentityAndVariables() throws {
        let store = RoleplayStore.shared
        let sessionID = UUID()
        let script = RoleplayHelperScript(name: "状态脚本", content: "window.fixture = true;",
                                          buttons: [.init(name: "显示"), .init(name: "隐藏", visible: false)], metadata: ["data": .dictionary(["initial": .int(1)])])
        var character = RoleplayCharacter(name: "网页角色")
        character.helperScripts = [script, .init(name: "未启用", content: "", enabled: false)]
        character.regexRules = [.init(findRegex: "状态占位", replaceString: "<div>状态页面</div>")]
        try store.saveCharacterDraft(character, replacing: nil)
        store.upsertBinding(.init(sessionID: sessionID, characterIDs: [character.id], helperScriptsEnabled: true))
        defer { store.removeBinding(sessionID: sessionID); store.deleteCharacter(id: character.id) }
        let message = ChatMessage(role: .assistant, content: "状态占位")
        let first = RoleplayPresentationSnapshot(sessionID: sessionID, messages: [message], worldbooks: [])
        let visual = first.visualContent(message, rules: [])
        let extraction = try #require(first.extraction(for: message, content: visual))
        let html = try #require(first.documents(for: message, extraction: extraction).first)
        #expect(html.html.contains("TavernHelper"))
        #expect(html.source == "<div>状态页面</div>")
        #expect(message.content == "状态占位")
        #expect(first.scriptDocuments().count == 1)
        #expect(first.buttons().map(\.name) == ["显示"])
        let firstScript = try #require(first.scriptDocuments().first)
        #expect(firstScript.variableUpdate.contains("initial"))

        let draft = try store.dataDraft(sessionID: sessionID, target: .variables(.chat, messageID: nil, versionIndex: 0))
        try store.saveDataDraft(draft, values: ["value": .int(9)])
        let second = RoleplayPresentationSnapshot(sessionID: sessionID, messages: [message], worldbooks: [])
        let updated = try #require(second.scriptDocuments().first)
        #expect(updated.id == firstScript.id)
        #expect(updated.variableUpdate != firstScript.variableUpdate)
        var edited = message
        edited.content = "修改后的历史"
        let changed = RoleplayPresentationSnapshot(sessionID: sessionID, messages: [edited], worldbooks: [])
        #expect(changed.scriptDocuments().first?.id != updated.id)

        var streaming = ChatMessage(role: .assistant, content: "尚未完整的 HTML")
        streaming.isReceivingStream = true
        let pending = RoleplayPresentationSnapshot(sessionID: sessionID, messages: [message, streaming], worldbooks: [])
        #expect(pending.extraction(for: streaming, content: "<div>未完成") == nil)
        #expect(pending.scriptDocuments().first?.id == updated.id)
    }

    @Test("字典插入顺序不会重复触发变量更新")
    func variableUpdateIsCanonical() {
        let id = UUID()
        let first = RoleplayVariableSnapshot(chat: ["a": .int(1), "b": .dictionary(["d": .int(4), "c": .int(3)])])
        let second = RoleplayVariableSnapshot(chat: ["b": .dictionary(["c": .int(3), "d": .int(4)]), "a": .int(1)])
        #expect(RoleplayHTMLDocumentFactory.makeVariableUpdateScript(variableSnapshot: first, messageID: id, messageVersionIndex: 0)
                == RoleplayHTMLDocumentFactory.makeVariableUpdateScript(variableSnapshot: second, messageID: id, messageVersionIndex: 0))
    }

    #if canImport(JavaScriptCore)
    @Test("脚本作用域保留初始默认值，网页更新刷新脚本和消息变量 API")
    func scriptVariableAPIsFollowNativeUpdates() throws {
        let scriptID = UUID(), message = ChatMessage(role: .assistant, content: "状态")
        var variables = RoleplayVariableSnapshot()
        variables.replaceScriptVariables(["count": .int(1)], scriptID: scriptID)
        variables.replaceMessageVariables(["score": .int(2)], messageID: message.id, versionIndex: 0)
        let defaults: [String: JSONValue] = ["initial": .int(7)]
        let document = RoleplayHTMLDocumentFactory.makeDocument(source: "<div></div>", variables: [:], userName: "用户", characterName: "角色",
                                                              userAvatarPath: "", characterAvatarPath: "", chatMessages: [message],
                                                              variableSnapshot: variables, messageID: message.id, scriptID: scriptID,
                                                              scriptInitialVariables: defaults)
        let start = try #require(document.range(of: "<script>(function () {")?.lowerBound)
        let scriptStart = document.index(start, offsetBy: "<script>".count)
        let end = try #require(document.range(of: "</script>", range: scriptStart..<document.endIndex)?.lowerBound)
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in Issue.record("脚本变量桥接异常：\(exception?.toString() ?? "未知错误")") }
        context.evaluateScript("""
        var window = this;
        window.webkit = { messageHandlers: { etosRoleplay: { postMessage: () => {} } } };
        window.addEventListener = function() {};
        window.dispatchEvent = function() {};
        var document = { readyState: 'loading', addEventListener: () => {}, querySelector: () => null,
          createElement: () => ({ innerHTML: '', setAttribute: () => {}, appendChild: () => {} }), body: {}, documentElement: {} };
        var File = function() {}, CustomEvent = function() {}, Audio = function() {};
        var MutationObserver = function() { this.observe = function() {}; };
        var ResizeObserver = function() { this.observe = function() {}; };
        """)
        context.evaluateScript(String(document[scriptStart..<end]))
        #expect(context.evaluateScript("getVariables({type:'script'}).initial")?.toInt32() == 7)
        variables.replaceScriptVariables(["count": .int(9)], scriptID: scriptID)
        variables.replaceMessageVariables(["score": .int(8)], messageID: message.id, versionIndex: 0)
        context.evaluateScript(RoleplayHTMLDocumentFactory.makeVariableUpdateScript(variableSnapshot: variables, messageID: message.id,
                                                                                  messageVersionIndex: 0, scriptID: scriptID, scriptInitialVariables: defaults))
        #expect(context.evaluateScript("getVariables({type:'script'}).count")?.toInt32() == 9)
        #expect(context.evaluateScript("getVariables({type:'script'}).initial")?.toInt32() == 7)
        #expect(context.evaluateScript("getVariables({type:'message'}).score")?.toInt32() == 8)
    }
    #endif

    @Test("追加历史保留旧索引，消息编辑、版本切换、改绑与删除拒绝旧网页写入")
    func staleBridgeSourcesAreRejected() async throws {
        let store = RoleplayStore.shared
        let service = ChatService(roleplayStore: store)
        let session = service.createSavedSession(name: "网页来源")
        let message = ChatMessage(role: .assistant, content: "原内容")
        service.updateMessages([message], for: session.id)
        defer { store.removeBinding(sessionID: session.id); service.deleteSessions([session]) }
        let source = RoleplayBridgeSourceSnapshot(sessionID: session.id, binding: nil, characters: [], messages: [message])
        #expect(source.isCurrent(service: service))
        service.updateMessages([message, .init(role: .user, content: "追加")], for: session.id)
        #expect(source.isCurrent(service: service))
        var changed = message
        changed.addVersion("新版本")
        service.updateMessages([changed], for: session.id)
        #expect(!source.isCurrent(service: service))
        await RoleplayBridgeDispatcher.handle(["action": "set_variable", "scope": "chat", "path": "stale", "value": true],
                                             sessionID: session.id, messageID: message.id, versionIndex: 0,
                                             service: service, validateSource: { source.isCurrent(service: service) }).value
        #expect(store.variableSnapshot(sessionID: session.id).chat["stale"] == nil)
        service.updateMessages([message], for: session.id)
        store.upsertBinding(.init(sessionID: session.id))
        #expect(!source.isCurrent(service: service))
        store.removeBinding(sessionID: session.id)
        service.updateMessages([], for: session.id)
        #expect(!source.isCurrent(service: service))
    }
}
