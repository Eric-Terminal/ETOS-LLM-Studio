// ============================================================================
// ETAdvancedMarkdownRenderer+MathWebViewPayload.swift
// ============================================================================
// iOS 数学 WebView 渲染组件的渲染 payload 与 JavaScript 调用封装。
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

extension ETMathWebViewRepresentable {

    struct Payload: Equatable {
        let content: String
        let availableWidth: CGFloat
        let bodyFontFamily: String
        let emphasisFontFamily: String
        let strongFontFamily: String
        let codeFontFamily: String

        var javaScriptInvocation: String {
            let widthString = String(format: "%.0f", availableWidth)
            let contentJSON = Self.jsonStringLiteral(content)
            let bodyFontFamilyJSON = Self.jsonStringLiteral(bodyFontFamily)
            let emphasisFontFamilyJSON = Self.jsonStringLiteral(emphasisFontFamily)
            let strongFontFamilyJSON = Self.jsonStringLiteral(strongFontFamily)
            let codeFontFamilyJSON = Self.jsonStringLiteral(codeFontFamily)
            return """
window.__etApplyPayload && window.__etApplyPayload({
  content: \(contentJSON),
  availableWidth: \(widthString),
  bodyFontFamily: \(bodyFontFamilyJSON),
  emphasisFontFamily: \(emphasisFontFamilyJSON),
  strongFontFamily: \(strongFontFamilyJSON),
  codeFontFamily: \(codeFontFamilyJSON)
});
window.__etNotifyHeight && window.__etNotifyHeight();
"""
        }

        static func jsonStringLiteral(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let json = String(data: data, encoding: .utf8),
                  json.count >= 2 else {
                return "\"\""
            }
            return String(json.dropFirst().dropLast())
        }
    }
}
