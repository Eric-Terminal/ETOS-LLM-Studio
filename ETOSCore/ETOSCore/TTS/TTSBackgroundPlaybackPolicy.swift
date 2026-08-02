// ============================================================================
// TTSBackgroundPlaybackPolicy.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义朗读请求在应用后台时是否可以继续播放。
// ============================================================================

import Foundation

enum TTSBackgroundPlaybackPolicy {
    nonisolated static func allowsPlayback(
        isApplicationInBackground: Bool,
        continuePlaybackInBackground: Bool
    ) -> Bool {
        !isApplicationInBackground || continuePlaybackInBackground
    }
}
