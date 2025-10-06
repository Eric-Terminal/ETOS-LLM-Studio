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
    let speed: Double // 速度，单位：像素/秒
    let delay: TimeInterval
    let spacing: CGFloat
    
    // MARK: - 状态变量
    
    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var isAnimating = false
    
    private var isScrollNeeded: Bool {
        textWidth > containerWidth
    }
    
    private var animation: Animation {
        let duration = (textWidth + spacing) / speed
        return Animation.linear(duration: duration)
            .delay(delay)
            .repeatForever(autoreverses: false)
    }
    
    // MARK: - 初始化
    
    public init(content: String, uiFont: UIFont = .preferredFont(forTextStyle: .headline), speed: Double = 40.0, delay: TimeInterval = 1.0, spacing: CGFloat = 40.0) {
        self.content = content
        self.uiFont = uiFont
        self.speed = speed
        self.delay = delay
        self.spacing = spacing
    }
    
    // MARK: - 视图主体
    
    public var body: some View {
        GeometryReader { geometry in
            // 使用一个不可见的视图来测量容器宽度
            Color.clear
                .onAppear {
                    containerWidth = geometry.size.width
                }
                .onChange(of: geometry.size.width) { oldWidth, newWidth in
                    containerWidth = newWidth
                }
            
            // 如果需要滚动，则创建滚动视图
            if isScrollNeeded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        textToScroll
                        // 复制一份文本以实现无缝滚动
                        textToScroll
                    }
                    .offset(x: isAnimating ? -(textWidth + spacing) : 0)
                }
                .disabled(true) // 禁用用户手动滚动
                .onAppear {
                    // 延迟后启动动画
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        withAnimation(animation) {
                            isAnimating = true
                        }
                    }
                }
            } else {
                // 如果不需要滚动，则显示静态文本
                textToScroll
            }
        }
        .frame(height: uiFont.lineHeight)
    }
    
    // MARK: - 辅助视图
    
    private var textToScroll: some View {
        Text(content)
            .font(Font(uiFont))
            .fixedSize(horizontal: true, vertical: false)
            .background(
                // 使用一个不可见的视图来测量文本宽度
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            textWidth = geometry.size.width
                        }
                        .onChange(of: content) { oldContent, newContent in
                            // 当文本内容变化时重新测量
                            textWidth = geometry.size.width
                        }
                }
            )
    }
}
