// ============================================================================
// ChatViewSendFlight.swift
// 发送状态只负责消息身份与显隐交接；实际内容快照和逐帧运动由原生表面承接。
// ============================================================================

import Foundation
import SwiftUI
import UIKit
import ETOSCore

struct SendFlightState: Equatable {
    let id: UUID
    let sessionID: UUID?
    var sourcesByMessageID: [UUID: ChatSendPresentationSource] = [:]
    var responseGroupID: UUID?

    func hidesDuringFlight(_ message: ChatMessage) -> Bool {
        if sourcesByMessageID[message.id] != nil { return true }
        guard let responseGroupID, message.responseGroupID == responseGroupID else { return false }
        return message.role == .assistant || message.role == .tool || message.role == .error
    }
}

struct FlightTargetRectKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $0.union($1) })
    }
}

enum ChatFlightBubbleStyle {
    static func colors(colorScheme: ColorScheme, enableBackground: Bool) -> [CGColor] {
        let profile = ChatAppearanceProfileManager.shared.activeProfile
        let fallback = Color(red: 0.24, green: 0.56, blue: 0.95)
        let start = profile.userBubble.isEnabled
            ? ChatAppearanceColorCodec.color(from: profile.userBubble.hex, fallback: fallback)
            : fallback
        let end = profile.userBubble.isEnabled
            ? ChatAppearanceColorCodec.darkened(start, factor: 0.86)
            : Color(red: 0.17, green: 0.45, blue: 0.82)
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let opacity: CGFloat = enableBackground ? 0.85 : 1
        return [start, end].map { UIColor($0).resolvedColor(with: traits).withAlphaComponent(opacity).cgColor }
    }
}

extension ChatView {
    func beginSendFlight(text: String, localAgentMode: LocalAgentMode) {
        cancelSendFlight()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sourceIDs: [ChatSendPresentationSource] = []
        if !trimmed.isEmpty { sourceIDs.append(.text) }
        sourceIDs.append(contentsOf: viewModel.pendingImageAttachments.map { .image($0.id) })
        sourceIDs.append(contentsOf: viewModel.pendingFileAttachments.map { .file($0.id) })
        if let audio = viewModel.pendingAudioAttachment { sourceIDs.append(.audio(audio.id)) }
        guard !accessibilityReduceMotion,
              let surface = sendFlightController.surface else {
            viewModel.sendMessage(localAgentMode: localAgentMode)
            return
        }
        let captures = sendFlightSources.capture(in: surface, ids: sourceIDs)
        guard !captures.isEmpty else {
            viewModel.sendMessage(localAgentMode: localAgentMode)
            return
        }

        let id = UUID()
        let response = min(max(appConfig.chatSendAnimationSpringResponse, 0.2), 0.8)
        let configuredDamping = min(max(appConfig.chatSendAnimationSpringDamping, 0.4), 1)
        let damping = 0.76 + (configuredDamping - 0.4) / 0.6 * 0.18
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flightHandoffProgress = 0
            flightState = SendFlightState(
                id: id,
                sessionID: viewModel.currentSession?.id
            )
        }

        sendFlightController.begin(
            id: id,
            captures: captures,
            response: response,
            damping: damping,
            colors: ChatFlightBubbleStyle.colors(colorScheme: colorScheme, enableBackground: viewModel.enableBackground),
            onMessagesPrepared: { presentation in
                guard var state = flightState, state.id == id,
                      state.sessionID == presentation.sessionID,
                      viewModel.currentSession?.id == presentation.sessionID else { return }
                let captured = sendFlightController.capturedSources
                state.sourcesByMessageID = Dictionary(uniqueKeysWithValues:
                    presentation.messageIDsBySource.compactMap { source, messageID in
                        captured.contains(source) ? (messageID, source) : nil
                    }
                )
                state.responseGroupID = presentation.responseGroupID
                flightState = state
            },
            onSourcesRetired: { sources in
                guard var state = flightState, state.id == id else { return }
                state.sourcesByMessageID = state.sourcesByMessageID.filter { !sources.contains($0.value) }
                flightState = state
            },
            onHandoff: {
                guard flightState?.id == id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    flightHandoffProgress = 1
                }
            },
            onCompletion: {
                guard flightState?.id == id else { return }
                cancelSendFlight()
            }
        )
        // 消息插入由列表的几何协调处理，避免一次全局动画让旧气泡也重新弹跳。
        viewModel.sendMessage(localAgentMode: localAgentMode) { [weak controller = sendFlightController] presentation in
            controller?.accept(presentation, for: id)
        }
    }

    func handleFlightTargetRect(_ frames: [UUID: CGRect]) {
        guard let state = flightState else { return }
        let targets = Dictionary(uniqueKeysWithValues: frames.compactMap { messageID, frame in
            state.sourcesByMessageID[messageID].map { ($0, frame) }
        })
        sendFlightController.retarget(targets)
    }

    func isSendFlightTarget(_ messageID: UUID) -> Bool {
        flightState?.sourcesByMessageID[messageID] != nil
    }

    func sendFlightMessageOpacity(for message: ChatMessage) -> Double {
        guard let state = flightState else { return 1 }
        return state.hidesDuringFlight(message) ? Double(flightHandoffProgress) : 1
    }

    var flightOverlayLayer: some View {
        ChatSendFlightSurface(controller: sendFlightController)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(40)
    }

    func cancelSendFlight() {
        sendFlightController.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flightState = nil
            flightHandoffProgress = 0
        }
    }

    static var flightCoordinateSpace: String { "chatFlight" }
}
