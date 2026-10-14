import ETOSCore
import Foundation
import SwiftUI
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacFontTests {
    @Test("优先级目录保持保存顺序，并在后台准备可添加项与向导标识")
    func chainCatalogPreservesPriority() throws {
        let first = asset("第一项"), second = asset("第二项"), third = asset("第三项")
        let catalog = MacFontDraftCatalog(.init(body: [second.id, first.id]), assets: [first, second, third])
        let chain = try #require(catalog.roles[.body])
        #expect(chain.selected.map(\.id) == [second.id, first.id])
        #expect(chain.available.map(\.id) == [third.id])
        #expect(chain.guideValue == .array([.string(second.id.uuidString), .string(first.id.uuidString)]))
        #expect(catalog.roles[.code]?.selected.isEmpty == true)
    }

    @Test("字体优先级提案拒绝未知标识、重复标识和非数组")
    func guideRejectsInvalidPriority() throws {
        let id = UUID(), allowed: Set<UUID> = [id]
        #expect(try MacFontChainEditor.ids(.array([.string(id.uuidString)]), allowed: allowed) == [id])
        for value in [JSONValue.string(id.uuidString), .array([.string(UUID().uuidString)]), .array([.string(id.uuidString), .string(id.uuidString)])] {
            #expect(throws: GuideError.self) { try MacFontChainEditor.ids(value, allowed: allowed) }
        }
    }

    @Test("规则字体排序仅修改内存草稿，保留表达式和其他字段")
    @MainActor func ruleChainDraftPreservesFields() async {
        let first = asset("第一项"), second = asset("第二项"), assets = [first, second]
        let rule = ChatAppearanceTextFontRule(kind: .regularExpression, exactText: "目标.+", fontAssetIDs: [first.id])
        let draft = MacFontRuleDraft(rule: rule, chain: .init(rule.fontAssetIDs, assets: assets), assets: assets)
        await draft.replaceChain([second.id, first.id])
        #expect(draft.rule.fontAssetIDs == [second.id, first.id])
        #expect(draft.rule.exactText == rule.exactText && draft.rule.kind == rule.kind && draft.rule.id == rule.id)
        #expect(rule.fontAssetIDs == [first.id])
    }

    @Test("改变正文行距刷新排版缓存，完整原文及既有 Markdown 解析保持不变")
    func lineSpacingInvalidatesTypography() async throws {
        let store = MacMessagePresentationStore(), message = ChatMessage(role: .assistant, content: "**完整正文**\n第二行")
        let first = try #require(try await store.prepare([message], markdown: true, language: "en", lineSpacing: 0).first)
        let changed = try #require(try await store.prepare([message], markdown: true, language: "en", lineSpacing: 0.5).first)
        #expect(first.content.typography.lineSpacing == 0 && changed.content.typography.lineSpacing > 0)
        #expect(first.content.id == changed.content.id && changed.content.source == message.content)
        #expect(changed.content.markdown != nil && changed.message == message)
    }

    @Test("后台准备用户预览与思考字体，活跃思考仍不应用着色和字体规则")
    func previewsKeepLiveReasoningPlain() async throws {
        let user = ChatMessage(role: .user, content: "完整用户内容"), store = MacMessagePresentationStore()
        var assistant = ChatMessage(role: .assistant, content: "")
        assistant.reasoningContent = "**正在思考**"; assistant.isReceivingStream = true
        let rows = try await store.prepare([user, assistant], markdown: true, language: "en", activeResponseID: assistant.id, userPreviewLimit: 2, lineSpacing: 0.5)
        #expect(rows[0].userPreview?.typography.lineSpacing == rows[0].content.typography.lineSpacing)
        let reasoning = try #require(rows[1].reasoning)
        #expect(reasoning.markdown == nil && reasoning.lightRules == nil && reasoning.darkRules == nil)
        #expect(reasoning.typography.lineSpacing > 0)
    }

    @Test("规则渲染请求将桌面语义字号纳入缓存身份，默认移动字号保持原行为")
    func semanticFontParticipatesInCacheIdentity() {
        let styles = ChatAppearanceTextStyleColors(defaultHex: "000000FF")
        let mobile = ChatAppearanceTextRuleRenderRequest(source: "**正文**", usesMarkdown: true, styleColors: styles)
        let desktop = ChatAppearanceTextRuleRenderRequest(source: mobile.source, usesMarkdown: true, styleColors: styles, semanticFont: .system(size: 13))
        #expect(mobile.semanticFont == .body && desktop.semanticFont == .system(size: 13))
        #expect(mobile != desktop)
    }

    @Test("字体向导说明分别声明父草稿保存、系统面板和已接受写入边界")
    func guideExplainsDraftAndFileBoundaries() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh_CN")).content
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en_US")).content
        #expect(chinese.contains("规则窗口的完成只返回父草稿") && chinese.contains("不承诺跨文件崩溃原子性"))
        #expect(english.contains("Done returns a rule to the parent draft") && english.contains("drain accepted file writes"))
    }

    private func asset(_ name: String) -> FontAssetRecord {
        FontAssetRecord(fileName: name + ".ttf", checksum: name, displayName: name, postScriptName: name)
    }
}
