// ============================================================================
// MessageReadAloudButton.swift
// ETOS LLM Studio
//
// 两端功能栏复用现有 TTS 服务，仅按钮自身订阅与当前消息有关的朗读状态。
// ============================================================================

import Combine
import Foundation
import SwiftUI

@MainActor
public struct MessageReadAloudButton: View {
    private let messageID: UUID
    private let currentMessage: () -> ChatMessage
    private let ttsManager = TTSManager.shared
    @State private var isReading = false

    public init(messageID: UUID, currentMessage: @escaping () -> ChatMessage) {
        self.messageID = messageID
        self.currentMessage = currentMessage
    }

    public var body: some View {
        Button {
            if ttsManager.currentSpeakingMessageID == messageID && ttsManager.isSpeaking {
                ttsManager.stop()
            } else {
                // 点击时取当前版本原文，避免朗读显示层的截断文本或旧版本。
                let message = currentMessage()
                guard MessageActionBarAvailability.canReadAloud(message) else { return }
                ttsManager.speak(message.content, messageID: message.id, flush: true)
            }
        } label: {
            Image(systemName: isReading ? "stop.fill" : "speaker.wave.2")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isReading
            ? NSLocalizedString("停止朗读", value: "Stop Reading", comment: "功能栏停止朗读按钮")
            : NSLocalizedString("朗读消息", value: "Read Message", comment: "功能栏朗读按钮"))
        // 不订阅音频进度，避免进度计时器反复刷新所有消息气泡。
        .onReceive(
            ttsManager.$currentSpeakingMessageID
                .combineLatest(ttsManager.$isSpeaking)
                .map { [messageID] speakingMessageID, isSpeaking in
                    speakingMessageID == messageID && isSpeaking
                }
                .removeDuplicates()
        ) { isReading = $0 }
    }
}
