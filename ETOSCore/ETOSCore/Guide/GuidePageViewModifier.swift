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
    let isActive: Bool
    let snapshot: GuideContextCoordinator.SnapshotProvider
    let executeReadTool: GuideContextCoordinator.ReadToolExecutor
    let buildProposal: GuideContextCoordinator.ProposalBuilder
    let execute: GuideContextCoordinator.ProposalExecutor

    @State private var token: GuideContextCoordinator.RegistrationToken?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard isActive else { return }
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
            .onChange(of: descriptor) { _, _ in
                guard let token else { return }
                GuideContextCoordinator.shared.update(
                    token,
                    descriptor: descriptor,
                    isFallback: isFallback,
                    snapshot: snapshot,
                    executeReadTool: executeReadTool,
                    buildProposal: buildProposal,
                    execute: execute
                )
            }
            .onChange(of: isActive) { _, active in
                if active {
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
                } else if let token {
                    GuideContextCoordinator.shared.unregister(token)
                    self.token = nil
                }
            }
    }
}

@MainActor
public extension View {
    /// 注册当前页面公开的快照与自定义工具；读取由页面执行，任何写入都必须先生成提案。
    func guidePageContext(
        descriptor: GuidePageDescriptor,
        isFallback: Bool = false,
        isActive: Bool = true,
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
            isActive: isActive,
            snapshot: snapshot,
            executeReadTool: executeReadTool,
            buildProposal: buildProposal,
            execute: execute
        ))
    }

    /// 为普通设置页生成受字段白名单约束的向导上下文；未声明的设置不能被读取或修改。
    func guideSettingsPageContext(
        id: GuidePageID,
        title: String,
        documents: [GuideDocumentReference] = [],
        isActive: Bool = true,
        settings: [GuidePageSetting]
    ) -> some View {
        let tool = GuideDeclarativeSettingsSupport.toolDefinition(
            pageTitle: title,
            settings: settings
        )
        let hasEditableSetting = settings.contains { $0.access != .readOnly }
        return guidePageContext(
            descriptor: GuidePageDescriptor(
                id: id,
                title: title,
                documents: documents,
                tools: hasEditableSetting
                    ? [GuidePageTool(definition: tool, access: .proposeChange)]
                    : []
            ),
            isActive: isActive,
            snapshot: {
                GuideDeclarativeSettingsSupport.snapshot(settings: settings)
            },
            buildProposal: { call, snapshot in
                try GuideDeclarativeSettingsSupport.buildProposal(
                    call: call,
                    pageID: id,
                    pageTitle: title,
                    settings: settings,
                    snapshot: snapshot
                )
            },
            execute: { proposal in
                try GuideDeclarativeSettingsSupport.execute(
                    proposal: proposal,
                    pageID: id,
                    pageTitle: title,
                    settings: settings
                )
            }
        )
    }
}
