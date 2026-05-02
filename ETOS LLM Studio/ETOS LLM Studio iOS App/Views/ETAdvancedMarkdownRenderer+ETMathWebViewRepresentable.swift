// ============================================================================
// ETAdvancedMarkdownRenderer+ETMathWebViewRepresentable.swift
// ============================================================================
// iOS 数学 WebView 渲染组件的状态、配置与基础声明。
// ============================================================================

import Foundation
import SwiftUI
import MarkdownUI
import Shared
import WebKit
import UIKit
#if canImport(SwiftMath)
import SwiftMath
#endif


struct ETMathWebViewRepresentable: UIViewRepresentable {
    let content: String
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let customTextHex: String?
    let prefersDarkPalette: Bool
    let fontScale: Double
    let availableWidth: CGFloat
    @Binding var renderedHeight: CGFloat
}
