// ============================================================================
// PersistenceNotificationThreadingTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证后台持久化操作不会从后台线程驱动界面状态发布。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("持久化通知线程", .serialized)
struct PersistenceNotificationThreadingTests {
    @Test("后台写入完成后在主线程发布本地数据变更通知")
    func postsLocalDataChangeNotificationOnMainThread() async {
        let notificationCenter = NotificationCenter()
        let observer = PersistenceNotificationObserverToken()

        let wasDeliveredOnMainThread = await withCheckedContinuation { continuation in
            let token = notificationCenter.addObserver(
                forName: .cloudSyncLocalDataDidChange,
                object: nil,
                queue: nil
            ) { _ in
                continuation.resume(returning: Thread.isMainThread)
            }
            observer.store(token)

            DispatchQueue.global(qos: .utility).async {
                Persistence.postCloudSyncLocalDataDidChange(notificationCenter: notificationCenter)
            }
        }

        observer.remove(from: notificationCenter)
        #expect(wasDeliveredOnMainThread)
    }
}

private final class PersistenceNotificationObserverToken: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    func store(_ token: NSObjectProtocol) {
        lock.lock()
        self.token = token
        lock.unlock()
    }

    func remove(from notificationCenter: NotificationCenter) {
        lock.lock()
        let current = token
        token = nil
        lock.unlock()
        if let current {
            notificationCenter.removeObserver(current)
        }
    }
}
