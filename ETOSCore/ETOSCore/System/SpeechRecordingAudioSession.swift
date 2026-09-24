// ============================================================================
// SpeechRecordingAudioSession.swift
// ETOS LLM Studio
//
// 录音会话的配置与启停按提交顺序在后台完成，避免主线程等待音频路由切换。
// ============================================================================

import AVFoundation
import Foundation

public final class SpeechRecordingAudioSession: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.etos.speech.audio-session", qos: .userInitiated)
    private let setActive: @Sendable (Bool) throws -> Void
    // 仅由 queue 访问；串行顺序确保旧录音的停用不会迟到并关闭下一次录音。
    private var isActive = false

    public convenience init() {
        self.init { active in
            let session = AVAudioSession.sharedInstance()
            if active {
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true)
            } else {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    init(setActive: @escaping @Sendable (Bool) throws -> Void) {
        self.setActive = setActive
    }

    // 与界面的取消操作在同一 actor 上提交，避免激活尚未入队时取消已先执行。
    @MainActor
    public func activate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.queue.async { [self] in
                do {
                    try setActive(true)
                    isActive = true
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func deactivate() {
        Self.queue.async { [self] in
            // 视图消失也会清理录音；没有取得过会话时不能打断其他音频功能。
            guard isActive else { return }
            try? setActive(false)
            isActive = false
        }
    }
}
