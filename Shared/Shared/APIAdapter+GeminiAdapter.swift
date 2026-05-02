// ============================================================================
// APIAdapter.swift
// ============================================================================
// 定义了与不同 LLM API 后端交互的适配器模式。
//
// 核心组件:
// - APIAdapter 协议: 定义了所有 API 适配器必须遵守的通用接口 (已重构)。
// - OpenAIAdapter 类: 针对 OpenAI 及其兼容 API 的具体实现 (已重构)。
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
