// ============================================================================
// ChatViewSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 ChatView 共享的轻量辅助类型、背景视图和滚动观察器。
// ============================================================================

import SwiftUI
import UIKit
import Photos
import UniformTypeIdentifiers
import ETOSCore

enum TelegramColors {
    static let navBarText = Color.primary
    static let navBarSubtitle = Color.secondary
    static let inputBackground = Color(uiColor: .systemBackground)
    static let inputFieldBackground = Color(uiColor: .secondarySystemBackground)
    static let inputBorder = Color(uiColor: .separator)
    static let attachButtonColor = Color(red: 0.33, green: 0.47, blue: 0.65)
    static let sendButtonColor = Color(red: 0.33, green: 0.47, blue: 0.65)
    static let scrollButtonBackground = Color(uiColor: .systemBackground)
    static let scrollButtonShadow = Color.black.opacity(0.15)
}

struct SessionPickerInfoPayload: Identifiable {
    let id = UUID()
    let session: ChatSession
    let messageCount: Int
    let isCurrent: Bool
}

func resolvedFileMimeType(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    if let type = UTType(filenameExtension: ext),
       let mimeType = type.preferredMIMEType {
        return mimeType
    }
    return "application/octet-stream"
}

struct ChatExportSharePayload: Identifiable {
    let id = UUID()
    let fileURL: URL
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]?

    init(activityItems: [Any], applicationActivities: [UIActivity]? = nil) {
        self.activityItems = activityItems
        self.applicationActivities = applicationActivities
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum ChatPickerSheet: String, Identifiable {
    case session
    case model

    var id: String { rawValue }
}

struct MessageActionSheetPayload: Identifiable {
    let id = UUID()
    let message: ChatMessage
}

struct MessageVersionDeletePayload: Identifiable {
    let id = UUID()
    let message: ChatMessage
    let index: Int
}

enum MessageActionExportScope: String, CaseIterable, Identifiable {
    case fullSession
    case upToMessage

    var id: String { rawValue }
}

struct MessageJumpRequest: Equatable {
    let token = UUID()
    let messageID: UUID
}

enum ChatAutomaticHistoryDirection: Equatable {
    case earlier
    case later
}

struct ChatAutomaticHistoryLoadRequest: Equatable {
    let direction: ChatAutomaticHistoryDirection
    let anchorMessageID: UUID
}

enum ChatMessageJumpAnimationPhase: Equatable {
    case adjacent
    case accelerating
    case cruising
    case decelerating
    case complete
}

enum ChatBubbleRendererIdentity: String, Hashable, Sendable {
    case none
    case plainText
    case streamingUIKit
    case nativeMarkdown
    case webMarkdown
    case roleplayHTML

    nonisolated static func resolved(
        hasContent: Bool,
        enableMarkdown: Bool,
        isStreaming: Bool,
        isAwaitingStaticHandoff: Bool,
        hasPreparedMarkdown: Bool,
        usesWebRenderer: Bool,
        hasRoleplayHTML: Bool = false
    ) -> Self {
        if hasRoleplayHTML { return .roleplayHTML }
        guard hasContent else { return .none }
        if isStreaming || isAwaitingStaticHandoff { return .streamingUIKit }
        guard enableMarkdown, hasPreparedMarkdown else { return .plainText }
        return usesWebRenderer ? .webMarkdown : .nativeMarkdown
    }
}

/// 只在会改变气泡高度的结构切换时重建视觉子树。
struct ChatBubbleLayoutIdentity: Hashable {
    let messageID: UUID
    let structuralRevision: UInt
    let layoutRecoveryRevision: UInt
    let isStreaming: Bool
    let hasPreparedMarkdown: Bool
    let hasPreparedReasoningMarkdown: Bool
    let usesNoBubbleStyle: Bool
    let contentRenderer: ChatBubbleRendererIdentity
    let reasoningRenderer: ChatBubbleRendererIdentity
    let layoutWidthBucket: Int

    init(
        messageID: UUID,
        structuralRevision: UInt,
        layoutRecoveryRevision: UInt = 0,
        isStreaming: Bool,
        isStaticMarkdownHandoffInProgress: Bool = false,
        hasPreparedMarkdown: Bool,
        hasPreparedReasoningMarkdown: Bool,
        usesNoBubbleStyle: Bool = false,
        contentRenderer: ChatBubbleRendererIdentity = .plainText,
        reasoningRenderer: ChatBubbleRendererIdentity = .none,
        layoutWidthBucket: Int = 0
    ) {
        let preservesStreamingView = isStreaming || isStaticMarkdownHandoffInProgress
        self.messageID = messageID
        self.structuralRevision = preservesStreamingView ? 0 : structuralRevision
        self.layoutRecoveryRevision = layoutRecoveryRevision
        self.isStreaming = preservesStreamingView
        // 交接期间冻结完整身份，避免任一通道先完成时重建另一通道的流式子树。
        self.hasPreparedMarkdown = preservesStreamingView ? false : hasPreparedMarkdown
        self.hasPreparedReasoningMarkdown = preservesStreamingView ? false : hasPreparedReasoningMarkdown
        self.usesNoBubbleStyle = usesNoBubbleStyle
        self.contentRenderer = preservesStreamingView ? .streamingUIKit : contentRenderer
        self.reasoningRenderer = preservesStreamingView ? .streamingUIKit : reasoningRenderer
        self.layoutWidthBucket = layoutWidthBucket
    }

    nonisolated static func widthBucket(for width: CGFloat?) -> Int {
        guard let width, width.isFinite, width > 0 else { return 0 }
        return Int((width / 8).rounded())
    }
}

enum ChatScrollTargetID: Hashable {
    case top
    case message(UUID)
    case bottom
}

struct SafeAreaBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatInputBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// iOS 18 起由 SwiftUI 在同一轮布局中处理静态尺寸变化；流式期间会主动关闭该锚点。
    @ViewBuilder
    func chatDefaultSizeChangeScrollAnchor(_ anchor: UnitPoint?) -> some View {
        if #available(iOS 18.0, *) {
            defaultScrollAnchor(anchor, for: .sizeChanges)
        } else {
            self
        }
    }

    /// 手势开始只由 UIKit 的真实拖动边沿认领；SwiftUI 阶段仅补充可靠的静止回报。
    @ViewBuilder
    func chatOnScrollIdle(_ action: @escaping () -> Void) -> some View {
        if #available(iOS 18.0, *) {
            onScrollPhaseChange { _, newPhase, _ in
                guard newPhase == .idle else { return }
                action()
            }
        } else {
            self
        }
    }
}

struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

struct TelegramDefaultBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { _ in
            ZStack {
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(red: 0.1, green: 0.12, blue: 0.15), Color(red: 0.08, green: 0.1, blue: 0.12)]
                        : [Color(red: 0.85, green: 0.9, blue: 0.92), Color(red: 0.88, green: 0.92, blue: 0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                TelegramPatternView()
                    .opacity(colorScheme == .dark ? 0.03 : 0.05)
            }
        }
        .ignoresSafeArea()
    }
}

struct TelegramPatternView: View {
    var body: some View {
        Canvas { context, size in
            let patternSize: CGFloat = 60
            let iconSize: CGFloat = 16

            for row in stride(from: 0, to: size.height + patternSize, by: patternSize) {
                for col in stride(from: 0, to: size.width + patternSize, by: patternSize) {
                    let offset = Int(row / patternSize) % 2 == 0 ? 0 : patternSize / 2
                    let x = col + offset
                    let y = row

                    let iconIndex = Int(x + y) % 4
                    let symbolName: String
                    switch iconIndex {
                    case 0: symbolName = "bubble.left.fill"
                    case 1: symbolName = "heart.fill"
                    case 2: symbolName = "star.fill"
                    default: symbolName = "paperplane.fill"
                    }

                    if let symbol = context.resolveSymbol(id: symbolName) {
                        context.draw(symbol, at: CGPoint(x: x, y: y))
                    } else {
                        let rect = CGRect(x: x - iconSize / 2, y: y - iconSize / 2, width: iconSize, height: iconSize)
                        context.fill(Circle().path(in: rect), with: .color(.gray))
                    }
                }
            }
        } symbols: {
            Image(systemName: "bubble.left.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("bubble.left.fill")

            Image(systemName: "heart.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("heart.fill")

            Image(systemName: "star.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("star.fill")

            Image(systemName: "paperplane.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("paperplane.fill")
        }
    }
}
