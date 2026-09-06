// ============================================================================
// BrowserAgentAdvancedTests.swift
// ============================================================================
// Browser Agent 高级协议、稳定元素定位与页面脚本边界测试。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("Browser Agent 高级能力测试")
struct BrowserAgentAdvancedTests {
    @Test("能力模型可解码旧版伴侣响应")
    func capabilitiesDecodeWithoutSupportedActions() throws {
        let data = Data(
            """
            {
              "platform": "watchOS",
              "isExperimental": true,
              "supportsNavigation": true,
              "supportsSnapshot": true,
              "supportsClick": true,
              "supportsTyping": true,
              "supportsScrolling": true,
              "supportsJavaScript": true,
              "supportsScreenshot": false,
              "supportsDownload": false,
              "supportsUserTakeover": true,
              "supportsIPhoneDelegation": true,
              "notes": []
            }
            """.utf8
        )

        let capabilities = try JSONDecoder().decode(BrowserAgentCapabilities.self, from: data)

        #expect(capabilities.platform == "watchOS")
        #expect(capabilities.supportedActions == nil)
    }

    @Test("工具协议包含高级动作但不暴露 Cookie 操作")
    func actionSurfaceExcludesCookies() {
        let actions = Set(BrowserAgentAction.allCases.map(\.rawValue))

        #expect(actions.contains("get_readable"))
        #expect(actions.contains("scroll_and_collect"))
        #expect(actions.contains("wait_for_dom_stable"))
        #expect(actions.contains("fetch"))
        #expect(!actions.contains("get_cookies"))
        #expect(!actions.contains("set_cookies"))
        #expect(!actions.contains("import_cookies"))
        #expect(!actions.contains("export_cookies"))
    }

    @Test("页面元素结果保留稳定 ID、DOM 版本与几何信息")
    func parsesStableElementMetadata() throws {
        let snapshot = try BrowserDOMResultParser.snapshot([
            "title": "示例",
            "url": "https://example.com",
            "text": "正文",
            "domRevision": 12,
            "wasTruncated": false,
            "elements": [[
                "index": 3,
                "elementID": "element-9",
                "domRevision": 12,
                "role": "button",
                "label": "继续",
                "text": "继续填写",
                "isVisible": true,
                "bounds": ["x": 10, "y": 20, "width": 80, "height": 44],
                "actions": ["click", "hover"]
            ]]
        ])

        let element = try #require(snapshot.elements.first)
        #expect(element.elementID == "element-9")
        #expect(element.domRevision == 12)
        #expect(element.text == "继续填写")
        #expect(element.bounds.width == 80)
        #expect(element.actions == ["click", "hover"])
    }

    @Test("陈旧元素结果要求模型重新定位")
    func staleElementProducesTypedError() {
        do {
            try BrowserDOMResultParser.interactionError([
                "error": "stale_element",
                "expectedRevision": 7,
                "actualRevision": 9
            ])
            Issue.record("陈旧元素没有抛出错误。")
        } catch BrowserAgentError.staleElement(let expected, let actual) {
            #expect(expected == 7)
            #expect(actual == 9)
        } catch {
            Issue.record("陈旧元素返回了错误类型：\(error.localizedDescription)")
        }
    }

    @Test("页面脚本正确保留正则与字符串转义")
    func pageScriptsPreserveJavaScriptEscapes() throws {
        let readable = BrowserReadableContent.script
        let typed = try BrowserDOMAutomation.type(
            elementID: "element-1",
            elementIndex: nil,
            domRevision: 2,
            text: "引号'和换行\n",
            submit: false
        )

        #expect(readable.contains(#"/\n{3,}/g"#))
        #expect(readable.contains(#"'\n\n'"#))
        #expect(typed.contains(#"\n"#))
    }
}
