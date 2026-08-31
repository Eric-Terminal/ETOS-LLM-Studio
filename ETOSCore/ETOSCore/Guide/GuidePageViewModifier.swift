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
    let isFallback: Bool
    let snapshot: GuideContextCoordinator.SnapshotProvider
    let executeReadTool: GuideContextCoordinator.ReadToolExecutor
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
                        isFallback: isFallback,
                        snapshot: snapshot,
                        executeReadTool: executeReadTool,
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
    /// 注册当前页面公开的快照与自定义工具；读取由页面执行，任何写入都必须先生成提案。
    func guidePageContext(
        descriptor: GuidePageDescriptor,
        isFallback: Bool = false,
        snapshot: @escaping @MainActor @Sendable () async -> GuidePageSnapshot,
        executeReadTool: @escaping @MainActor @Sendable (InternalToolCall) async throws -> String = { call in
            throw GuideError.unsupportedTool(call.toolName)
        },
        buildProposal: @escaping @MainActor @Sendable (InternalToolCall, GuidePageSnapshot) throws -> GuideActionProposal = { _, _ in
            throw GuideError.invalidToolArguments
        },
        execute: @escaping @MainActor @Sendable (GuideActionProposal) async throws -> GuideActionExecution = { _ in
            throw GuideError.invalidToolArguments
        }
    ) -> some View {
        modifier(GuidePageContextModifier(
            descriptor: descriptor,
            isFallback: isFallback,
            snapshot: snapshot,
            executeReadTool: executeReadTool,
            buildProposal: buildProposal,
            execute: execute
        ))
    }
}
