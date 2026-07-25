// ============================================================================
// SlashCommandSettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件提供 iOS 斜杠命令的总开关与命令速查。
// ============================================================================

import SwiftUI
import ETOSCore

struct SlashCommandSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared

    var body: some View {
        Form {
            Section {
                Toggle(
                    NSLocalizedString("启用斜杠命令", comment: "Enable slash commands toggle"),
                    isOn: $appConfig.enableSlashCommands
                )
            } footer: {
                Text(NSLocalizedString("默认关闭。启用后，在聊天输入框输入 / 即可筛选并执行命令；无法识别的内容仍会原样发送给 AI。", comment: "Slash commands setting footer"))
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
                                .etFont(.caption)
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
        .navigationTitle(NSLocalizedString("斜杠命令", comment: "Slash command settings title"))
    }
}
