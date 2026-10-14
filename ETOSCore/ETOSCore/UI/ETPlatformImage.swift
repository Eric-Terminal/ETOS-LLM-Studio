// ============================================================================
// ETPlatformImage.swift
// ============================================================================
// 后台图像解码共用 ImageIO，只在交给界面时使用各平台的不可变图像载体。
// ============================================================================

#if canImport(UIKit)
import UIKit
public typealias ETPlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias ETPlatformImage = NSImage
#endif
