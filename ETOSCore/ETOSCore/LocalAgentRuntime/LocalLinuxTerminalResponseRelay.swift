// ============================================================================
// LocalLinuxTerminalResponseRelay.swift
// ============================================================================
// ETOS LLM Studio
//
// 终端身份与光标查询属于终端协议回包，不受用户/Agent 输入所有权控制。会话
// 建立前收到的查询先暂存，建立后再按原顺序写回同一 PTY。
// ============================================================================

import Foundation

final class LocalLinuxTerminalResponseRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var session: iSHAppleBridgeTerminalSession?
    private var pending = Data()
    private var lastWrite: Task<Void, Never>?

    func bind(to session: iSHAppleBridgeTerminalSession) {
        lock.lock()
        self.session = session
        let buffered = pending
        pending.removeAll(keepingCapacity: false)
        if !buffered.isEmpty { schedule(buffered, on: session) }
        lock.unlock()
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard let session else {
            pending.append(data)
            lock.unlock()
            return
        }
        schedule(data, on: session)
        lock.unlock()
    }

    private func schedule(_ data: Data, on session: iSHAppleBridgeTerminalSession) {
        let previous = lastWrite
        lastWrite = Task.detached(priority: .userInitiated) {
            await previous?.value
            try? await session.send(data)
        }
    }
}
