// ============================================================================
// GuidePageViewModifier.swift
// ============================================================================
// ETOS LLM Studio
//
// 页面必须主动声明向导可见的数据和操作；视图层不会自动抓取屏幕或数据库。
// ============================================================================

import SwiftUI

@MainActor
private struct GuidePageContextModifier: ViewModifier {
    let descriptor: GuidePageDescriptor
    let snapshot: GuideContextCoordinator.SnapshotProvider
    let buildProposal: GuideContextCoordinator.ProposalBuilder
    let execute: GuideContextCoordinator.ProposalExecutor

    @State private var token: GuideContextCoordinator.RegistrationToken?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if let token {
                    GuideContextCoordinator.shared.activate(token)
                } else {
                    token = GuideContextCoordinator.shared.register(
                        descriptor: descriptor,
                        snapshot: snapshot,
                        buildProposal: buildProposal,
                        execute: execute
                    )
                }
            }
            .onDisappear {
                guard let token else { return }
                GuideContextCoordinator.shared.unregister(token)
                self.token = nil
            }
    }
}

@MainActor
public extension View {
    /// 注册当前页面允许向导读取的快照及提案式写入工具。
    func guidePageContext(
        descriptor: GuidePageDescriptor,
        snapshot: @escaping @MainActor @Sendable () async -> GuidePageSnapshot,
        buildProposal: @escaping @MainActor @Sendable (InternalToolCall, GuidePageSnapshot) throws -> GuideActionProposal = { _, _ in
            throw GuideError.invalidToolArguments
        },
        execute: @escaping @MainActor @Sendable (GuideActionProposal) async throws -> GuideActionExecution = { _ in
            throw GuideError.invalidToolArguments
        }
    ) -> some View {
        modifier(GuidePageContextModifier(
            descriptor: descriptor,
            snapshot: snapshot,
            buildProposal: buildProposal,
            execute: execute
        ))
    }
}
