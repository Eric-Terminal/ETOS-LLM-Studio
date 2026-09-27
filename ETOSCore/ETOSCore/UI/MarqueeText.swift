// ============================================================================
// MarqueeText.swift
// ============================================================================
// ETOS LLM Studio Watch App 自定义视图文件
//
// 功能特性:
// - 实现一个可复用的、自动水平滚动的“跑马灯”文本视图
// - 当文本内容超过容器宽度时，会自动启动循环滚动动画
// ============================================================================

import SwiftUI

public struct MarqueeText: View {
    // MARK: - 属性
    
    let content: String
    let uiFont: UIFont
    let customFont: Font?
    let speed: Double // 速度，单位：像素/秒
    let delay: TimeInterval
    let spacing: CGFloat
    
    // MARK: - 状态变量
    
    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var textHeight: CGFloat = 0
    @State private var isVisible = false
    @Environment(\.font) private var environmentFont
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    
    // MARK: - 初始化
    
    public init(content: String, uiFont: UIFont = .preferredFont(forTextStyle: .headline), font: Font? = nil, speed: Double = 40.0, delay: TimeInterval = 1.0, spacing: CGFloat = 40.0) {
        self.content = content
        self.uiFont = uiFont
        self.customFont = font
        self.speed = speed
        self.delay = delay
        self.spacing = spacing
    }
    
    // MARK: - 视图主体
    
    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if canAnimate {
                    MarqueeScrollingText(
                        content: content,
                        font: resolvedFont,
                        textWidth: textWidth,
                        spacing: spacing,
                        speed: speed,
                        delay: delay
                    )
                    // 新内容与新几何需要从开头重新阅读；移除旧子树也会终止旧的循环动画。
                    .id(animationIdentity)
                } else {
                    Text(content)
                        .font(resolvedFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .clipped()
            .background(alignment: .leading) {
                // 始终测量同一份完整文字，避免静态截断宽度反过来关闭跑马灯。
                Text(content)
                    .font(resolvedFont)
                    .fixedSize(horizontal: true, vertical: false)
                    .hidden()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        textWidth = size.width
                        textHeight = size.height
                    }
                    .accessibilityHidden(true)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                containerWidth = width
            }
        }
        .frame(height: max(uiFont.lineHeight, textHeight))
        // 两份视觉副本只代表一段内容；静态截断也不能截断 VoiceOver 的朗读。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: content))
        .onAppear {
            isVisible = true
        }
        .onDisappear {
            isVisible = false
        }
    }

    private var canAnimate: Bool {
        isVisible && scenePhase == .active && !reduceMotion && !voiceOverEnabled
            && containerWidth > 0 && textWidth > containerWidth && speed > 0
    }

    private var animationIdentity: MarqueeAnimationIdentity {
        MarqueeAnimationIdentity(
            content: content,
            textWidth: textWidth,
            textHeight: textHeight,
            containerWidth: containerWidth,
            spacing: spacing,
            speed: speed,
            delay: delay
        )
    }

    private var resolvedFont: Font {
        if let customFont {
            return customFont
        }
        if let environmentFont {
            return environmentFont
        }
        return Font(uiFont)
    }
}

private struct MarqueeAnimationIdentity: Hashable {
    let content: String
    let textWidth: CGFloat
    let textHeight: CGFloat
    let containerWidth: CGFloat
    let spacing: CGFloat
    let speed: Double
    let delay: TimeInterval
}

private struct MarqueeScrollingText: View {
    let content: String
    let font: Font
    let textWidth: CGFloat
    let spacing: CGFloat
    let speed: Double
    let delay: TimeInterval

    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: spacing) {
            Text(content).font(font)
            Text(content).font(font)
        }
        .fixedSize(horizontal: true, vertical: false)
        .offset(x: isAnimating ? -(textWidth + spacing) : 0)
        .task {
            // 让初始位置先进入视图事务；任务随子树销毁取消，不遗留延迟回调。
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(
                .linear(duration: (textWidth + spacing) / speed)
                    .delay(delay)
                    .repeatForever(autoreverses: false)
            ) {
                isAnimating = true
            }
        }
    }
}
