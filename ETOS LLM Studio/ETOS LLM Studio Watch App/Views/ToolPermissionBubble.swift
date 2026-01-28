// ============================================================================
// ToolPermissionBubble.swift
// ============================================================================
// MCP 工具权限请求气泡
// - 显示工具名称与参数
// - 提供允许与更多操作
// ============================================================================

import SwiftUI
import Shared

struct ToolPermissionBubble: View {
    let request: ToolPermissionRequest
    let enableBackground: Bool
    let enableLiquidGlass: Bool
    let onDecision: (ToolPermissionDecision) -> Void
    @State private var isShowingMoreOptions = false

    private var toolName: String {
        request.displayName ?? request.toolName
    }

    private var trimmedArguments: String {
        request.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var bubbleFill: Color {
        enableBackground ? Color.black.opacity(0.3) : Color(white: 0.3)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("工具：\(toolName)")
                    .font(.caption)
                    .foregroundColor(.primary)

                if !trimmedArguments.isEmpty {
                    Text("参数：")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    ScrollView {
                        Text(trimmedArguments)
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                    }
                    .frame(maxHeight: 120)
                }

                HStack(spacing: 6) {
                    Button("允许") {
                        onDecision(.allowOnce)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isShowingMoreOptions.toggle()
                        }
                    } label: {
                        Label("更多", systemImage: "ellipsis")
                    }
                    .buttonStyle(.bordered)
                }

                if isShowingMoreOptions {
                    HStack(spacing: 6) {
                        Button("拒绝", role: .destructive) {
                            onDecision(.deny)
                        }
                        .buttonStyle(.bordered)

                        Button("补充提示") {
                            onDecision(.supplement)
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 6) {
                        Button("保持允许") {
                            onDecision(.allowForTool)
                        }
                        .buttonStyle(.bordered)

                        Button("完全权限") {
                            onDecision(.allowAll)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(10)
            .background(bubbleBackground)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        if enableLiquidGlass {
            if #available(watchOS 26.0, *) {
                shape
                    .fill(bubbleFill)
                    .glassEffect(.clear, in: shape)
                    .clipShape(shape)
            } else {
                shape
                    .fill(bubbleFill)
            }
        } else {
            shape
                .fill(bubbleFill)
        }
    }
}
