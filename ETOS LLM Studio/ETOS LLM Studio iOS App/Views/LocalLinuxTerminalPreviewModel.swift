// ============================================================================
// LocalLinuxTerminalPreviewModel.swift
// ============================================================================
// ETOS LLM Studio
//
// 为聊天页的悬浮与停靠终端缩略图共享活动终端和实时输出状态。
// ============================================================================

import Combine
import ETOSCore
import Foundation

@MainActor
final class LocalLinuxTerminalPreviewModel: ObservableObject {
    @Published private(set) var activeTerminalID: UUID?
    @Published private(set) var activeTerminalCount = 0
    @Published private(set) var presentation = LocalLinuxTerminalPresentation.empty

    func observeActivity(isEnabled: Bool) async {
        guard isEnabled else {
            reset()
            return
        }

        let updates = await LocalLinuxRuntimeController.shared.updates()
        for await snapshot in updates {
            guard !Task.isCancelled else { return }
            if snapshot.activeTerminalCount == 0 {
                reset()
                continue
            }

            let terminals = await LocalLinuxJobScheduler.shared.activeStandaloneUserTerminals()
            let terminalIDs = terminals.map(\.id)
            activeTerminalCount = terminalIDs.count
            let nextID = activeTerminalID.flatMap { terminalIDs.contains($0) ? $0 : nil }
                ?? terminalIDs.first
            if activeTerminalID != nextID {
                activeTerminalID = nextID
                presentation = .empty
            }
        }
    }

    func observeOutput(
        appearance: LocalLinuxTerminalAppearance,
        maximumLines: Int
    ) async {
        guard let terminalID = activeTerminalID else { return }
        while !Task.isCancelled, activeTerminalID == terminalID {
            do {
                presentation = try await LocalLinuxJobScheduler.shared
                    .userVisibleTerminalPreviewPresentation(
                        jobID: terminalID,
                        maximumLines: maximumLines,
                        appearance: appearance
                    )
            } catch {
                reset()
                return
            }

            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
        }
    }

    private func reset() {
        activeTerminalID = nil
        activeTerminalCount = 0
        presentation = .empty
    }
}
