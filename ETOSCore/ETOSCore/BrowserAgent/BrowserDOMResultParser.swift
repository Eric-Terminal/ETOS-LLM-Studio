// ============================================================================
// BrowserDOMResultParser.swift
// ============================================================================
// ETOS LLM Studio
//
// 页面脚本结果在进入工具输出前转换为可验证的 Codable 模型。
// ============================================================================

import Foundation

enum BrowserDOMResultParser {
    static func snapshot(_ object: [String: Any]) throws -> BrowserAgentSnapshot {
        let revision = integer(object["domRevision"]) ?? 0
        return BrowserAgentSnapshot(
            title: object["title"] as? String ?? "",
            url: object["url"] as? String,
            text: object["text"] as? String ?? "",
            elements: elements(object["elements"], fallbackRevision: revision),
            wasTruncated: object["wasTruncated"] as? Bool ?? false,
            domRevision: revision
        )
    }

    static func elements(_ value: Any?, fallbackRevision: Int) -> [BrowserAgentSnapshot.Element] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let index = integer(item["index"]),
                  let elementID = item["elementID"] as? String,
                  let role = item["role"] as? String,
                  let label = item["label"] as? String,
                  let bounds = item["bounds"] as? [String: Any] else {
                return nil
            }
            return BrowserAgentSnapshot.Element(
                index: index,
                elementID: elementID,
                domRevision: integer(item["domRevision"]) ?? fallbackRevision,
                role: role,
                label: label,
                text: item["text"] as? String,
                value: item["value"] as? String,
                isVisible: item["isVisible"] as? Bool ?? false,
                bounds: BrowserAgentElementBounds(
                    x: number(bounds["x"]) ?? 0,
                    y: number(bounds["y"]) ?? 0,
                    width: number(bounds["width"]) ?? 0,
                    height: number(bounds["height"]) ?? 0
                ),
                actions: item["actions"] as? [String] ?? []
            )
        }
    }

    static func pageInfo(_ object: [String: Any]) -> BrowserAgentPageInfo {
        BrowserAgentPageInfo(
            title: object["title"] as? String ?? "",
            url: object["url"] as? String,
            canonicalURL: object["canonicalURL"] as? String,
            language: object["language"] as? String,
            contentType: object["contentType"] as? String,
            viewportWidth: number(object["viewportWidth"]) ?? 0,
            viewportHeight: number(object["viewportHeight"]) ?? 0,
            scrollWidth: number(object["scrollWidth"]) ?? 0,
            scrollHeight: number(object["scrollHeight"]) ?? 0,
            linkCount: integer(object["linkCount"]) ?? 0,
            formCount: integer(object["formCount"]) ?? 0,
            domRevision: integer(object["domRevision"]) ?? 0
        )
    }

    static func readable(_ object: [String: Any]) -> BrowserAgentReadableContent {
        BrowserAgentReadableContent(
            title: object["title"] as? String ?? "",
            byline: object["byline"] as? String,
            publishedAt: object["publishedAt"] as? String,
            text: object["text"] as? String ?? "",
            links: object["links"] as? [String] ?? [],
            wasTruncated: object["wasTruncated"] as? Bool ?? false
        )
    }

    static func interactionError(_ value: Any?) throws {
        guard let object = value as? [String: Any], let error = object["error"] as? String else { return }
        if error == "stale_element" {
            throw BrowserAgentError.staleElement(
                expectedRevision: integer(object["expectedRevision"]),
                actualRevision: integer(object["actualRevision"]) ?? 0
            )
        }
        throw BrowserAgentError.javaScriptFailed(
            NSLocalizedString("页面元素已不存在，请重新定位。", comment: "Browser Agent element missing")
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        return (value as? NSNumber)?.doubleValue
    }
}
