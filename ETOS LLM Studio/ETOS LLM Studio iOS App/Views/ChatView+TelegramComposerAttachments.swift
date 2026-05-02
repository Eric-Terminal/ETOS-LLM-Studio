// ============================================================================
// ChatView+TelegramComposerAttachments.swift
// ============================================================================
// iOS Telegram 风格输入栏的附件预览、文件导入与音频处理。
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
