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

extension ChatView {
    @discardableResult
    func beginSendFlight(text: String, localAgentMode: LocalAgentMode) -> Bool {
        cancelSendFlight()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sourceIDs: [ChatSendPresentationSource] = []
        if !trimmed.isEmpty { sourceIDs.append(.text) }
        sourceIDs.append(contentsOf: viewModel.pendingImageAttachments.map { .image($0.id) })
        sourceIDs.append(contentsOf: viewModel.pendingFileAttachments.map { .file($0.id) })
        if let audio = viewModel.pendingAudioAttachment { sourceIDs.append(.audio(audio.id)) }
        guard !accessibilityReduceMotion,
              let surface = sendFlightController.surface,
              let departureBounds = sendFlightController.departureBounds else {
            return viewModel.sendMessage(localAgentMode: localAgentMode)
        }
        let captures = sendFlightSources.capture(in: surface, ids: sourceIDs)
        guard !captures.isEmpty else {
            return viewModel.sendMessage(localAgentMode: localAgentMode)
        }

        let id = UUID()
        let response = min(max(appConfig.chatSendAnimationSpringResponse, 0.2), 0.8)
        let configuredDamping = min(max(appConfig.chatSendAnimationSpringDamping, 0.4), 1)
        let damping = 0.76 + (configuredDamping - 0.4) / 0.6 * 0.18
        let colors = ChatOutgoingBubbleColors(profile: ChatAppearanceProfileManager.shared.activeProfile)
        let backgrounds = Dictionary(uniqueKeysWithValues: captures.compactMap { capture in
            ChatSendFlightBackground.resolved(
                for: capture.source, colors: colors,
                enableBackground: viewModel.enableBackground,
                enableLiquidGlass: isLiquidGlassEnabled
            ).map { (capture.source, $0) }
        })
        var transaction = Transaction()
        transaction.disablesAnimations = true
        // 同步清空草稿与附件也属于这次发送，避免紧接着以默认事务再提交一轮页面更新。
        return withTransaction(transaction) {
            flightHandoffProgress = 0
            flightState = SendFlightState(
                id: id,
                sessionID: viewModel.currentSession?.id
            )
            // 先完成同步草稿捕获；Core 任务要等当前 MainActor 调用返回后才可能交回身份。
            // 原生浮层从清空工作结束后开始计时，避免尚未展示就耗尽等待预算。
            let consumedDraft = viewModel.sendMessage(localAgentMode: localAgentMode) { [weak controller = sendFlightController] presentation in
                controller?.accept(presentation, for: id)
            }
            guard consumedDraft else {
                cancelSendFlight()
                return false
            }
            sendFlightController.begin(
                id: id,
                sessionID: viewModel.currentSession?.id,
                captures: captures,
                response: response,
                damping: damping,
                backgrounds: backgrounds,
                departureBounds: departureBounds,
                onMessagesPrepared: { presentation in
                    guard var state = flightState, state.id == id,
                          state.sessionID == presentation.sessionID,
                          viewModel.currentSession?.id == presentation.sessionID else { return false }
                    let captured = sendFlightController.capturedSources
                    state.sourcesByMessageID = Dictionary(uniqueKeysWithValues:
                        presentation.messageIDsBySource.compactMap { source, messageID in
                            captured.contains(source) ? (messageID, source) : nil
                        }
                    )
                    state.responseGroupID = presentation.responseGroupID
                    flightState = state
                    // 展示事件可能先于此处的 UI 身份绑定，仅在绑定时补确认一次现成索引。
                    confirmSendFlightDisplayedSources(in: Set(viewModel.displayMessageIDs))
                    return true
                },
                onSourcesRetired: { sources in
                    guard var state = flightState, state.id == id else { return }
                    state.sourcesByMessageID = state.sourcesByMessageID.filter { !sources.contains($0.value) }
                    flightState = state
                },
                onHandoff: { completedID, completedSessionID in
                    guard completedID == id, flightState?.id == id,
                          flightState?.sessionID == completedSessionID,
                          viewModel.currentSession?.id == completedSessionID else { return false }
                    withAnimation(.easeOut(duration: 0.12), completionCriteria: .removed) {
                        flightHandoffProgress = 1
                    } completion: {
                        guard flightState?.id == id,
                              flightState?.sessionID == completedSessionID,
                              viewModel.currentSession?.id == completedSessionID else { return }
                        sendFlightController.completeHandoff(for: id, sessionID: completedSessionID)
                    }
                    return true
                },
                onCompletion: {
                    guard flightState?.id == id else { return }
                    cancelSendFlight()
                }
            )
            return true
        }
    }

    func handleFlightTargetRect(_ frames: [UUID: CGRect]) {
        guard let state = flightState else { return }
        let targets = Dictionary(uniqueKeysWithValues: frames.compactMap { messageID, frame in
            state.sourcesByMessageID[messageID].map { ($0, frame) }
        })
        sendFlightController.retarget(targets)
    }

    func confirmSendFlightDisplayedSources(in messageIDs: Set<UUID>) {
        guard let state = flightState, state.sessionID == viewModel.currentSession?.id else { return }
        let sources = Set(state.sourcesByMessageID.compactMap { messageID, source in
            messageIDs.contains(messageID) ? source : nil
        })
        sendFlightController.updateDisplayedSources(sources, for: state.id, sessionID: state.sessionID)
    }

    func sendFlightTarget(for messageID: UUID) -> ChatSendFlightTarget? {
        guard let state = flightState, let source = state.sourcesByMessageID[messageID] else { return nil }
        return ChatSendFlightTarget(flightID: state.id, source: source)
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
