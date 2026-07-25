// ============================================================================
// SlashCommandSettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件提供 watchOS 快速指令的总开关与命令速查。
// ============================================================================

import SwiftUI
import ETOSCore

struct SlashCommandSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared

    var body: some View {
        List {
            Section {
                Toggle(
                    NSLocalizedString("启用快速指令", comment: "Enable quick commands toggle"),
                    isOn: $appConfig.enableSlashCommands
                )
            } footer: {
                Text(NSLocalizedString("默认关闭。启用后，提交以 / 开头的输入即可显示命令；无法识别的内容仍会原样发送给 AI。", comment: "Watch slash commands setting footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(ChatSlashCommand.allCases) { command in
                    Label {
                        VStack(alignment: .leading) {
                            Text(command.invocation)
                                .etFont(.body.monospaced())
                            Text(NSLocalizedString(command.titleLocalizationKey, comment: "Slash command description"))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: command.systemImage)
                            .foregroundStyle(.tint)
                    }
                }
            } header: {
                Text(NSLocalizedString("可用命令", comment: "Available slash commands section"))
            }
        }
        .navigationTitle(NSLocalizedString("快速指令", comment: "Quick command settings title"))
    }
}
