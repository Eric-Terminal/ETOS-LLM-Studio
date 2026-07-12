// ============================================================================
// RoleplayStoreThreadingTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证角色扮演存储的界面变更通知始终由主线程发布。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("角色扮演存储线程", .serialized)
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
