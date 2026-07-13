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
            regexRules: [RoleplayRegexRule(scriptName: "旧正则", findRegex: "old")],
            helperScripts: [RoleplayHelperScript(name: "旧脚本", content: "old")],
            extensions: ["vendor": .string("preserved")]
        )
        defer { store.deleteCharacter(id: character.id) }
        store.upsertCharacter(character)

        character.regexRules = [RoleplayRegexRule(scriptName: "新正则", findRegex: "new")]
        character.helperScripts = [RoleplayHelperScript(name: "新脚本", content: "new")]
        store.upsertCharacter(character)

        let saved = store.character(id: character.id)
        #expect(saved?.regexRules.first?.scriptName == "新正则")
        #expect(saved?.helperScripts.first?.content == "new")
        #expect(saved?.extensions["vendor"] == .string("preserved"))
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
