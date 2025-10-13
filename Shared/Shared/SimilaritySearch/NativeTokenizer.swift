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

    /// 使用正则表达式将文本分割成词元数组，保留单词和标点。
    public func tokenize(text: String) -> [String] {
        do {
            // 这个正则表达式会匹配一串连续的单词字符(\w+)或一串连续的非单词、非空白字符([^\s\w]+)
            let regex = try NSRegularExpression(pattern: "\\w+|[^\\s\\w]+")
            let results = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            return results.map { String(text[Range($0.range, in: text)!]) }
        } catch {
            print("无效的正则表达式: \(error.localizedDescription)")
            return []
        }
    }

    /// 将词元数组合并回单个字符串
    public func detokenize(tokens: [String]) -> String {
        return tokens.joined(separator: " ")
    }
}
