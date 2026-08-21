// ============================================================================
// RoleplayStoreThreadingTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证角色扮演存储的线程约束与角色卡内容持久化。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("角色扮演存储", .serialized)
struct RoleplayStoreThreadingTests {
    @Test("后台保存完成后在主线程发布变更通知")
    func postsChangeNotificationOnMainThread() async {
        let store = RoleplayStore.shared
        let character = RoleplayCharacter(name: "线程回归测试")
        let observer = NotificationObserverToken()

        let wasDeliveredOnMainThread = await withCheckedContinuation { continuation in
            let token = NotificationCenter.default.addObserver(
                forName: RoleplayStore.didChangeNotification,
                object: store,
                queue: nil
            ) { notification in
                let changeKind = notification.userInfo?[RoleplayStore.changeKindUserInfoKey] as? String
                guard changeKind == RoleplayStore.libraryChangeKind else { return }
                continuation.resume(returning: Thread.isMainThread)
            }
            observer.store(token)

            DispatchQueue.global(qos: .utility).async {
                store.upsertCharacter(character)
            }
        }

        observer.remove()
        store.deleteCharacter(id: character.id)
        #expect(wasDeliveredOnMainThread)
    }

    @Test("角色卡内容编辑后保留扩展字段")
    func persistsEditableCharacterContentWithoutDroppingExtensions() {
        let store = RoleplayStore.shared
        var character = RoleplayCharacter(
            name: "内容编辑回归测试",
            description: "旧描述",
            firstMessage: "旧开场白",
            alternateGreetings: ["旧候选开场白"],
            regexRules: [RoleplayRegexRule(scriptName: "旧正则", findRegex: "old")],
            helperScripts: [RoleplayHelperScript(name: "旧脚本", content: "old")],
            initialVariables: ["score": .int(1)],
            extensions: ["vendor": .string("preserved")]
        )
        defer { store.deleteCharacter(id: character.id) }
        store.upsertCharacter(character)

        character.description = "新描述"
        character.firstMessage = "新开场白"
        character.alternateGreetings = ["新候选开场白一", "新候选开场白二"]
        character.systemPrompt = "新系统提示词"
        character.regexRules = [RoleplayRegexRule(scriptName: "新正则", findRegex: "new")]
        character.helperScripts = [RoleplayHelperScript(name: "新脚本", content: "new")]
        character.initialVariables = ["score": .int(2)]
        store.upsertCharacter(character)

        let saved = store.character(id: character.id)
        #expect(saved?.description == "新描述")
        #expect(saved?.firstMessage == "新开场白")
        #expect(saved?.alternateGreetings.count == 2)
        #expect(saved?.systemPrompt == "新系统提示词")
        #expect(saved?.regexRules.first?.scriptName == "新正则")
        #expect(saved?.helperScripts.first?.content == "new")
        #expect(saved?.initialVariables["score"] == .int(2))
        #expect(saved?.extensions["vendor"] == .string("preserved"))
    }

    @Test("未绑定角色卡时仍可保存用户身份")
    func persistsPersonaWithoutCharacterBinding() {
        let store = RoleplayStore.shared
        let previousPreferredPersonaID = store.preferredPersonaID()
        let sessionID = UUID()
        let persona = PersonaProfile(name: "独立用户身份")
        defer {
            store.removeBinding(sessionID: sessionID)
            store.deletePersona(id: persona.id)
            store.setPreferredPersonaID(previousPreferredPersonaID)
        }
        store.upsertPersona(persona)
        store.upsertBinding(SessionRoleplayBinding(
            sessionID: sessionID,
            characterIDs: [],
            personaID: persona.id
        ))

        let binding = store.binding(sessionID: sessionID)
        #expect(binding?.characterIDs.isEmpty == true)
        #expect(binding?.personaID == persona.id)
    }

    @Test("最近使用的用户身份可供新会话复用")
    func remembersPreferredPersonaAcrossSessions() {
        let store = RoleplayStore.shared
        let previousPreferredPersonaID = store.preferredPersonaID()
        let firstSessionID = UUID()
        let persona = PersonaProfile(name: "跨会话用户身份")
        defer {
            store.removeBinding(sessionID: firstSessionID)
            store.deletePersona(id: persona.id)
            store.setPreferredPersonaID(previousPreferredPersonaID)
        }
        store.upsertPersona(persona)
        store.upsertBinding(SessionRoleplayBinding(
            sessionID: firstSessionID,
            characterIDs: [],
            personaID: persona.id
        ))
        store.setPreferredPersonaID(persona.id)

        #expect(store.preferredPersonaID() == persona.id)
    }

    @Test("对话开始后更换用户身份会重算自动开场白宏")
    func changingPersonaRefreshesSeededGreetingAfterConversationStarted() throws {
        let store = RoleplayStore.shared
        let previousPreferredPersonaID = store.preferredPersonaID()
        let service = ChatService(roleplayStore: store)
        let character = RoleplayCharacter(
            name: "开场白宏回归测试",
            firstMessage: "<div>{{user}} 的状态栏</div>"
        )
        let firstPersona = PersonaProfile(name: "初始用户")
        let secondPersona = PersonaProfile(name: "更新用户")
        let session = service.createSavedSession(name: "开场白宏回归测试")
        defer {
            store.removeBinding(sessionID: session.id)
            store.deleteCharacter(id: character.id)
            store.deletePersona(id: firstPersona.id)
            store.deletePersona(id: secondPersona.id)
            store.setPreferredPersonaID(previousPreferredPersonaID)
            service.deleteSessions([session])
        }
        store.upsertCharacter(character)
        store.upsertPersona(firstPersona)
        store.upsertPersona(secondPersona)
        service.bindRoleplay(
            sessionID: session.id,
            characterIDs: [character.id],
            personaID: firstPersona.id
        )
        var legacyBinding = try #require(store.binding(sessionID: session.id))
        legacyBinding.seededGreetingMessageID = nil
        store.upsertBinding(legacyBinding)
        var messages = Persistence.loadMessages(for: session.id)
        #expect(messages.first?.content.contains("初始用户") == true)
        messages.append(ChatMessage(role: .user, content: "继续"))
        messages.append(ChatMessage(role: .assistant, content: "剧情继续"))
        service.updateMessages(messages, for: session.id)

        service.bindRoleplay(
            sessionID: session.id,
            characterIDs: [character.id],
            personaID: secondPersona.id,
            seedGreetingIfEmpty: false
        )

        let updatedGreeting = try #require(Persistence.loadMessages(for: session.id).first)
        #expect(updatedGreeting.content.contains("更新用户"))
        #expect(!updatedGreeting.content.contains("初始用户"))
    }

    @Test("最终角色回复在变量落盘后通知界面重算 HTML")
    func finalRoleplayReplyInvalidatesRenderedHTML() async {
        let store = RoleplayStore.shared
        let previousPreferredPersonaID = store.preferredPersonaID()
        let service = ChatService(roleplayStore: store)
        let character = RoleplayCharacter(name: "HTML 刷新回归测试")
        let loadingMessage = ChatMessage(role: .assistant, content: "")
        let session = service.createSavedSession(
            name: "HTML 刷新回归测试",
            initialMessages: [loadingMessage]
        )
        let collector = SessionNotificationCollector(sessionID: session.id)
        let token = NotificationCenter.default.addObserver(
            forName: RoleplayDisplayedMessageBridge.didChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            collector.record(notification)
        }
        defer {
            NotificationCenter.default.removeObserver(token)
            store.removeBinding(sessionID: session.id)
            store.deleteCharacter(id: character.id)
            store.setPreferredPersonaID(previousPreferredPersonaID)
            service.deleteSessions([session])
        }
        store.upsertCharacter(character)
        store.upsertBinding(SessionRoleplayBinding(
            sessionID: session.id,
            characterIDs: [character.id]
        ))

        await service.updateMessage(
            with: ChatMessage(
                role: .assistant,
                content: "<UpdateVariable>_.set('状态', '已更新');</UpdateVariable>"
            ),
            for: loadingMessage.id,
            in: session.id
        )

        #expect(collector.didReceive)
    }
}

private final class NotificationObserverToken: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    func store(_ token: NSObjectProtocol) {
        lock.lock()
        self.token = token
        lock.unlock()
    }

    func remove() {
        lock.lock()
        let current = token
        token = nil
        lock.unlock()
        if let current {
            NotificationCenter.default.removeObserver(current)
        }
    }
}

private final class SessionNotificationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let sessionID: UUID
    private var received = false

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    var didReceive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func record(_ notification: Notification) {
        guard notification.userInfo?[RoleplayBridgeNotification.sessionIDKey] as? UUID == sessionID else { return }
        lock.lock()
        received = true
        lock.unlock()
    }
}
