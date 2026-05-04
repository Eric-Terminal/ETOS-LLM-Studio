// ============================================================================
// ETAdvancedMarkdownRendererSupport.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 负责 watchOS Markdown 渲染器的代码块容器与复制按钮辅助。
// ============================================================================

import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ETWatchCollapsibleCodeBlockView<HeaderActions: View, BodyContent: View>: View {
    let language: String?
    let headerTextColor: Color
    let headerBackground: Color
    let blockBackground: Color
    let borderColor: Color
    let onHeaderTap: (() -> Void)?
    @ViewBuilder let headerActions: (_ isCollapsed: Bool) -> HeaderActions
    @ViewBuilder let bodyContent: () -> BodyContent

    @State private var isCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                codeBlockTitle

                Spacer(minLength: 8)

                headerActions(isCollapsed)

                ETCodeCollapseButton(
                    isCollapsed: isCollapsed,
                    tintColor: headerTextColor
                ) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        isCollapsed.toggle()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(headerBackground)
                }
            }

            if !isCollapsed {
                bodyContent()
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .move(edge: .top))
                        )
                    )
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isCollapsed)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(blockBackground)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var codeBlockTitle: some View {
        if let onHeaderTap {
            Button(action: onHeaderTap) {
                codeBlockTitleLabel
            }
            .buttonStyle(.plain)
        } else {
            codeBlockTitleLabel
        }
    }

    private var codeBlockTitleLabel: some View {
        Text(language?.isEmpty == false ? (language ?? NSLocalizedString("代码", comment: "")) : NSLocalizedString("代码", comment: ""))
            .etFont(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(headerTextColor)
            .contentShape(Rectangle())
    }
}

private struct ETCodeCollapseButton: View {
    let isCollapsed: Bool
    let tintColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                .etFont(.system(size: 10, weight: .semibold))
                .foregroundStyle(tintColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? NSLocalizedString("展开代码块", comment: "") : NSLocalizedString("折叠代码块", comment: ""))
    }
}

enum ETCodeClipboard {
    static var supportsCopy: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    static func copy(_ content: String) {
        #if os(iOS)
        UIPasteboard.general.string = content
        #endif
    }
}

struct ETCodeCopyButton: View {
    let content: String
    let normalColor: Color
    let successColor: Color

    @State private var didCopy = false

    var body: some View {
        Button {
            ETCodeClipboard.copy(content)
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif

            withAnimation(.easeInOut(duration: 0.15)) {
                didCopy = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    didCopy = false
                }
            }
        } label: {
            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                .etFont(.system(size: 10, weight: .semibold))
                .foregroundStyle(didCopy ? successColor : normalColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("复制代码", comment: ""))
    }
}
