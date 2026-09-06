// ============================================================================
// AudioAttachment.swift
// ============================================================================
// AudioAttachment 共享模块
// - 提供跨平台复用的核心能力
// - 支撑 iOS 与 watchOS 的业务一致性
// ============================================================================

import Foundation

public struct AudioAttachment: Sendable, Identifiable {
    // 同名录音也可能是新的草稿，试听生命周期不能只依赖文件名。
    public let id = UUID()
    public let data: Data
    public let mimeType: String
    public let format: String
    public let fileName: String
    
    public init(data: Data, mimeType: String, format: String, fileName: String) {
        self.data = data
        self.mimeType = mimeType
        self.format = format
        self.fileName = fileName
    }
}
