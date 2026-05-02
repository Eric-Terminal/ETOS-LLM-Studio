// ============================================================================
// ChatView.swift
// ============================================================================
// 聊天主界面 (iOS) - Telegram 风格
// - Telegram 风格的顶部导航栏（标题 + 副标题）
// - Telegram 风格的底部输入栏（圆角输入框 + 附件 + 发送按钮）
// - 支持壁纸背景、消息气泡
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
import UIKit
import PhotosUI
import Photos
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Telegram 主题颜色
extension TelegramMessageComposer {
    
    var glassOverlayColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.2)
    }
    
    var glassStrokeColor: Color {
        Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28)
    }
    
    var glassShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1)
    }
}
