// ============================================================================
// NativeTokenizer.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件源自 SimilaritySearchKit，定义了 NativeTokenizer 类。
// 它使用苹果的 NaturalLanguage 框架来实现分词功能。
// 我已根据项目规范，将注释和文件头修改为中文格式。
// ============================================================================

import Foundation
import NaturalLanguage
import CoreML

public class NativeTokenizer: TokenizerProtocol {
    public init() {}

    /// 使用 NLTokenizer 将文本分割成词元数组
    public func tokenize(text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let tokenRanges = tokenizer.tokens(for: text.startIndex..<text.endIndex).map { text[$0] }
        let tokens = tokenRanges.map { String($0) }
        return tokens
    }

    /// 将词元数组合并回单个字符串
    public func detokenize(tokens: [String]) -> String {
        return tokens.joined(separator: " ")
    }
}
