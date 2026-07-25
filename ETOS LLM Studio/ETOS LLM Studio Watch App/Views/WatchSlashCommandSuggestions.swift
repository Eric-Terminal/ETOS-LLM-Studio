// ============================================================================
// WatchSlashCommandSuggestions.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件呈现 watchOS 输入提交后的斜杠命令建议。
// ============================================================================

import SwiftUI
import ETOSCore

struct WatchSlashCommandSuggestionPanel: View {
    let commands: [ChatSlashCommand]
    let onSelect: (ChatSlashCommand) -> Void

    private let rowHeight: CGFloat = 42
    private let maximumPanelHeight: CGFloat = 152

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(commands) { command in
                    Button {
                        onSelect(command)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: command.systemImage)
                                .foregroundStyle(.tint)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(command.invocation)
                                    .etFont(.footnote.monospaced().weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(NSLocalizedString(command.titleLocalizationKey, comment: "Slash command description"))
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if command.id != commands.last?.id {
                        Divider()
                            .padding(.leading, 36)
                    }
                }
            }
        }
        .frame(height: min(CGFloat(commands.count) * rowHeight, maximumPanelHeight))
        .background(Color.primary.opacity(0.08), in: shape)
        .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("命令建议", comment: "Slash command suggestions accessibility label"))
    }
}
