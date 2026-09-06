// ============================================================================
// RoleplayHTMLDependencyResolver.swift
// ============================================================================
// ETOS LLM Studio
//
// 根据角色卡前端源码按需注入常见 CDN 依赖，避免未使用的资源阻塞首次显示。
// ============================================================================

import Foundation

enum RoleplayHTMLDependencyResolver {
    static func markup(for source: String) -> String {
        var tags: [String] = []

        if matches(#"(?:\bFontAwesome\b|\bfa(?:s|r|b|l|t|d)?\s+fa-|\bfa-[a-z0-9-]+)"#, in: source) {
            tags.append(#"<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.7.2/css/all.min.css">"#)
        }
        if matches(#"(?:^|[^\w$])\$\s*(?:\(|\.|\[)|\bjQuery\s*(?:\(|\.|\[)"#, in: source) {
            tags.append(#"<script src="https://cdn.jsdelivr.net/npm/jquery@3.7.1/dist/jquery.min.js"></script>"#)
        }
        if matches(#"(?:^|[^\w])_\s*(?:\(|\.|\[)|\blodash\b"#, in: source) {
            tags.append(#"<script src="https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js"></script>"#)
        }
        if matches(#"\bVue\s*(?:\.|\[)|\bvue\.global\b"#, in: source) {
            tags.append(#"<script src="https://cdn.jsdelivr.net/npm/vue@3.5.13/dist/vue.global.prod.js"></script>"#)
        }
        if matches(#"\bYAML\s*(?:\.|\[)|\byaml@\b"#, in: source) {
            tags.append(#"<script src="https://cdn.jsdelivr.net/npm/yaml@2.7.0/browser/dist/index.js"></script>"#)
        }
        if usesTailwind(in: source) {
            tags.append(#"<script src="https://cdn.tailwindcss.com"></script>"#)
        }

        return tags.joined(separator: "\n")
    }

    private static func usesTailwind(in source: String) -> Bool {
        if matches(#"(?:\btailwind(?:css)?\b|@tailwind\b)"#, in: source) {
            return true
        }

        // 普通 CSS 类名可能恰好包含 flex、grid 等单词；这里只把带参数的工具类视作 Tailwind 依赖。
        return matches(
            #"(?:^|[\s\"'=`])(?:[a-z0-9-]+:)*(?:[mp][trblxy]?|space-[xy]|gap|w|min-w|max-w|h|min-h|max-h|size|bg|text|font|leading|tracking|border|rounded|shadow|grid-cols|grid-rows|col-span|row-span|items|justify|self|place-(?:items|content|self)|overflow|object|opacity|z|inset|top|right|bottom|left|translate-[xy]|scale|rotate|skew-[xy]|origin|duration|delay|ease|animate)-[a-z0-9_./\[\]%-]+(?=$|[\s\"'`])"#,
            in: source
        )
    }

    private static func matches(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
