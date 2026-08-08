// ============================================================================
// LocalAgentModeWatchView.swift
// ============================================================================
// watchOS 的快捷按钮只负责进入此页；模式切换、运行状态与停止作用域在这里可见。
// ============================================================================

import ETOSCore
import SwiftUI

struct LocalAgentModeWatchView: View {
    let sessionID: UUID

    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var mode = LocalAgentMode.chat
    @State private var runtimePhase = LocalLinuxRuntimePhase.notInstalled
    @State private var activeRun: ConversationRun?
    @State private var executionBudget: ConversationExecutionBudget?

    var body: some View {
        List {
            Section {
                Picker(NSLocalizedString("模式", comment: "Watch local Agent mode picker"), selection: $mode) {
                    ForEach(LocalAgentMode.allCases) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .disabled(activeRun != nil)
                .onChange(of: mode) { _, value in
                    _ = Persistence.saveLocalAgentMode(value, sessionID: sessionID)
                }
            } header: {
                Text(NSLocalizedString("会话模式", comment: "Watch local Agent mode section"))
            } footer: {
                Text(NSLocalizedString("Agent 会向模型提供浏览器等工具；Linux 工具只在启用本地 Linux 后提供。", comment: "Watch local Agent mode footer"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("状态", comment: "Watch local Agent status section")) {
                if appConfig.localLinuxEnabled {
                    LabeledContent(
                        NSLocalizedString("Linux 运行时", comment: "Watch Linux runtime"),
                        value: runtimePhase.displayName
                    )
                }
                if mode == .agent, let executionBudget {
                    LabeledContent(
                        NSLocalizedString("自动执行预算", comment: "Watch local Agent execution budget"),
                        value: "\(max(0, executionBudget.maximumExecutions - executionBudget.usedExecutions))/\(executionBudget.maximumExecutions)"
                    )
                }
                if activeRun != nil {
                    Text(NSLocalizedString("当前 Agent Run 尚未结束；请先在任务页停止它，再切换会话模式。", comment: "Watch active Agent run mode switch guidance"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if appConfig.localLinuxEnabled {
                    NavigationLink(NSLocalizedString("本地 Agent 任务", comment: "Watch local Agent jobs title")) {
                        LocalLinuxWatchJobsView(sessionID: sessionID)
                    }
                }
                if let activeRun {
                    Button(NSLocalizedString("停止此 Agent", comment: "Watch stop Linux Agent run"), role: .destructive) {
                        Task {
                            await ChatService.shared.stopConversationRun(activeRun.id)
                            await reloadRunState()
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("Chat / Agent", comment: "Watch local Agent mode title"))
        .task(id: sessionID) {
            mode = await Task.detached(priority: .userInitiated) {
                Persistence.localAgentMode(sessionID: sessionID)
            }.value
            runtimePhase = await LocalLinuxRuntimeController.shared.snapshot().phase
            while !Task.isCancelled {
                await reloadRunState()
                try? await Task<Never, Never>.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .task {
            for await snapshot in await LocalLinuxRuntimeController.shared.updates() {
                if Task.isCancelled { break }
                runtimePhase = snapshot.phase
            }
        }
    }

    private func reloadRunState() async {
        let state = await Task.detached(priority: .utility) {
            guard let run = Persistence.loadLatestConversationRun(sessionID: sessionID),
                  !run.status.isTerminal else {
                return (run: Optional<ConversationRun>.none, budget: Optional<ConversationExecutionBudget>.none)
            }
            return (
                run: Optional(run),
                budget: Persistence.loadConversationExecutionBudget(rootRunID: run.rootRunID)
            )
        }.value
        activeRun = state.run
        executionBudget = state.budget
    }
}
