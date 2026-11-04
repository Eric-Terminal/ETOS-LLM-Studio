import Foundation
import SwiftUI
import Testing
@testable import ETOSCore

@MainActor
struct GuideContextCompressionSettingsTests {
    @Test("压缩向导只允许修改草稿，不暴露凭据或启动请求")
    func exposesDraftFieldsWithoutCredentials() throws {
        let provider = Provider(
            name: "测试提供商", baseURL: "https://example.com", apiKeys: ["private-api-key"],
            apiFormat: "openai-compatible", models: [Model(modelName: "test-model", isActivated: true)],
            headerOverrides: ["Authorization": "private-header"]
        )
        let model = RunnableModel(provider: provider, model: provider.models[0])
        let settings = GuideContextCompressionSettingsSupport.settings(
            sessionID: UUID(), models: [model], retainedRoundCount: .constant(2),
            modelIdentifier: .constant(model.id), focusInstruction: .constant("")
        )
        #expect(Set(settings.filter { $0.access == .readWrite }.map(\.key)) == Set(["retained_rounds", "model", "focus"]))
        let snapshot = GuideDeclarativeSettingsSupport.snapshot(settings: settings)
        #expect(snapshot.fields["requires_manual_creation"]?.value == .bool(true))
        #expect(snapshot.fields["model"]?.value == .string(model.id))
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!encoded.contains("private-api-key"))
        #expect(!encoded.contains("private-header"))

        for arguments in [#"{"model":"missing-model"}"#, #"{"requires_manual_creation":false}"#] {
            #expect(throws: GuideError.self) {
                _ = try GuideDeclarativeSettingsSupport.buildProposal(
                    call: InternalToolCall(id: "invalid", toolName: GuideDeclarativeSettingsSupport.toolName, arguments: arguments),
                    pageID: "compression-options", pageTitle: "压缩为续聊", settings: settings, snapshot: snapshot
                )
            }
        }
        let automaticProposal = try GuideDeclarativeSettingsSupport.buildProposal(
            call: InternalToolCall(id: "automatic", toolName: GuideDeclarativeSettingsSupport.toolName, arguments: #"{"model":""}"#),
            pageID: "compression-options", pageTitle: "压缩为续聊", settings: settings, snapshot: snapshot
        )
        #expect(automaticProposal.arguments["model"] == .string(""))
        #expect(throws: GuideError.self) {
            _ = try GuideDeclarativeSettingsSupport.execute(
                proposal: automaticProposal, pageID: "another-page", pageTitle: "其他页面", settings: settings
            )
        }
    }

    @Test("双语向导文档说明手动模型不回退及附件识别可能另用模型")
    func documentsModelRoutingBoundaries() {
        let chinese = GuideContextCompressionKnowledge.document(locale: Locale(identifier: "zh-Hans")).content
        let english = GuideContextCompressionKnowledge.document(locale: Locale(identifier: "en")).content
        #expect(chinese.contains("不自动改用其他账户"))
        #expect(chinese.contains("手表同时显示模型名与提供商"))
        #expect(chinese.contains("附件识别仍可能使用独立"))
        #expect(english.contains("never switches accounts"))
        #expect(english.contains("preserve edits when returning"))
        #expect(english.contains("Attachment recognition may still use separate"))
    }
}
