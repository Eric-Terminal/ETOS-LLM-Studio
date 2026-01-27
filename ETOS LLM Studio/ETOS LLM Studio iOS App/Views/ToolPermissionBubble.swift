// ============================================================================
// ToolPermissionBubble.swift
// ============================================================================
// MCP 工具权限请求气泡
// - 显示工具名称与参数
// - 提供允许与更多操作
// ============================================================================

import SwiftUI
import Shared
import UIKit

struct ToolPermissionBubble: View {
    let request: ToolPermissionRequest
    let enableBackground: Bool
    let enableLiquidGlass: Bool
    let onDecision: (ToolPermissionDecision) -> Void

    private var toolName: String {
        request.displayName ?? request.toolName
    }

    private var cappedArguments: String {
        let trimmedArguments = request.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedArguments.count > 600 {
            return String(trimmedArguments.prefix(600)) + "..."
        }
        return trimmedArguments
    }

    private var bubbleShape: TelegramBubbleShape {
        TelegramBubbleShape(isOutgoing: false)
    }

    private var bubbleGradient: some ShapeStyle {
        let assistantOpacity = enableBackground ? 0.75 : 1.0
        let baseColor = enableBackground
            ? Color(uiColor: .secondarySystemBackground).opacity(assistantOpacity)
            : Color(uiColor: .systemBackground)
        return AnyShapeStyle(baseColor)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("工具：\(toolName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)

                    if !cappedArguments.isEmpty {
                        Text("参数：\(cappedArguments)")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(6)
                    }
                }

                HStack(spacing: 8) {
                    Button("允许") {
                        onDecision(.allowOnce)
                    }
                    .buttonStyle(.borderedProminent)

                    Menu {
                        Button("拒绝", role: .destructive) {
                            onDecision(.deny)
                        }
                        Button("补充提示") {
                            onDecision(.supplement)
                        }
                        Button("保持允许") {
                            onDecision(.allowForTool)
                        }
                        Button("完全权限") {
                            onDecision(.allowAll)
                        }
                    } label: {
                        Label("更多", systemImage: "ellipsis")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(bubbleBackground)
            .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if enableLiquidGlass {
            if #available(iOS 26.0, *) {
                bubbleShape
                    .fill(bubbleGradient)
                    .glassEffect(.clear, in: bubbleShape)
                    .clipShape(bubbleShape)
            } else {
                bubbleShape
                    .fill(bubbleGradient)
            }
        } else {
            bubbleShape
                .fill(bubbleGradient)
        }
    }
}
