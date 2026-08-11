// ============================================================================
// LocalAgentModeWatchView.swift
// ============================================================================
// watchOS 的快捷按钮只负责进入此页；这里保持模式切换与必要的活动任务操作。
// ============================================================================

import ETOSCore
import SwiftUI

struct LocalAgentModeWatchView: View {
    let sessionID: UUID

    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var mode = LocalAgentMode.chat
    @State private var activeRun: ConversationRun?

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
            }

            if let activeRun {
                Section {
                    Text(NSLocalizedString("当前 Agent Run 尚未结束；请先在任务页停止它，再切换会话模式。", comment: "Watch active Agent run mode switch guidance"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("停止此 Agent", comment: "Watch stop Linux Agent run"), role: .destructive) {
                        Task {
                            await ChatService.shared.stopConversationRun(activeRun.id)
                            await reloadRunState()
                        }
                    }
                }
            }

            if appConfig.localLinuxEnabled {
                Section {
                    NavigationLink(NSLocalizedString("本地 Agent 任务", comment: "Watch local Agent jobs title")) {
                        LocalLinuxWatchJobsView(sessionID: sessionID)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("Chat / Agent", comment: "Watch local Agent mode title"))
        .task(id: sessionID) {
            mode = await Task.detached(priority: .userInitiated) {
                Persistence.localAgentMode(sessionID: sessionID)
            }.value
            while !Task.isCancelled {
                await reloadRunState()
                try? await Task<Never, Never>.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func reloadRunState() async {
        let state = await Task.detached(priority: .utility) {
            guard let run = Persistence.loadLatestConversationRun(sessionID: sessionID),
                  !run.status.isTerminal else {
                return Optional<ConversationRun>.none
            }
            return Optional(run)
        }.value
        activeRun = state
    }
}
