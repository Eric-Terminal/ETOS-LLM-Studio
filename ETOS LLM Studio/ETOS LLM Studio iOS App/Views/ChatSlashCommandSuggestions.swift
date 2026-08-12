// ============================================================================
// ChatSlashCommandSuggestions.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件呈现聊天输入框上方的 iOS 斜杠命令建议面板。
// ============================================================================

import SwiftUI
import ETOSCore

struct ChatSlashCommandSuggestionPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    let commands: [ChatSlashCommandSuggestion]
    let usesLiquidGlass: Bool
    let glassTintOpacity: Double
    let onSelect: (ChatSlashCommandSuggestion) -> Void

    private let rowHeight: CGFloat = 52
    private let maximumPanelHeight: CGFloat = 286

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        Group {
            if #available(iOS 26.0, *), usesLiquidGlass {
                panelContent
                    .background(shape.fill(glassOverlayColor))
                    .glassEffect(.clear.interactive(), in: shape)
                    .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            } else {
                panelContent
                    .background(
                        shape
                            .fill(.ultraThinMaterial)
                            .overlay(shape.fill(glassOverlayColor))
                            .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
                            .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                    )
            }
        }
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("命令建议", comment: "Slash command suggestions accessibility label"))
    }

    private var panelContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(commands) { command in
                    Button {
                        onSelect(command)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: command.systemImage)
                                .etFont(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.tint)
                                .frame(width: 24)

                            Text(command.invocation)
                                .etFont(.body.monospaced().weight(.semibold))
                                .foregroundStyle(.primary)

                            Text(command.displayDescription)
                                .etFont(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(command.invocation), \(command.displayDescription)"
                    )

                    if command.id != commands.last?.id {
                        Divider()
                            .padding(.leading, 52)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: min(CGFloat(commands.count) * rowHeight, maximumPanelHeight))
    }

    private var glassOverlayColor: Color {
        let opacity = LiquidGlassTintSetting.normalized(glassTintOpacity)
        return colorScheme == .dark ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
    }

    private var glassStrokeColor: Color {
        Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28)
    }

    private var glassShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1)
    }
}
