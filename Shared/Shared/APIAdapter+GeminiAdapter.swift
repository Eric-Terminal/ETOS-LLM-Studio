// ============================================================================
// APIAdapter+GeminiAdapter.swift
// ============================================================================
// Gemini API 适配器的类型声明、响应模型与媒体生成支持。
// ============================================================================

import Foundation
import CryptoKit
import os.log

// MARK: - 流式响应的数据片段



// MARK: - Gemini 适配器实现

/// `GeminiAdapter` 是 `APIAdapter` 协议的具体实现，专门用于处理 Google Gemini API。
/// Gemini API 使用 `contents`/`parts` 结构，系统提示使用独立的 `system_instruction` 字段。
public class GeminiAdapter: APIAdapter {
    
    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "GeminiAdapter")
    static let toolNameRegex = try! NSRegularExpression(pattern: "[^a-zA-Z0-9_.-]", options: [])
    
    public init() {}
}
