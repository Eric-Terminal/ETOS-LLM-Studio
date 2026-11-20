import Foundation
import Testing
@testable import ETOSCore

@Suite("反馈草稿向导")
struct FeedbackDraftGuideSupportTests {
    private let pageID: GuidePageID = "feedback-compose"
    private let original = FeedbackDraft(category: .suggestion, title: "", detail: "未分享的原文",
        reproductionSteps: "之前填写的步骤", expectedBehavior: nil, actualBehavior: "", extraContext: "私下的备注")

    private func call(_ arguments: String) -> InternalToolCall {
        InternalToolCall(id: "feedback", toolName: FeedbackDraftGuideSupport.toolName, arguments: arguments)
    }

    @Test("自动快照只公开类型与填写状态，主动提问只包含可见字段")
    func privacyBoundary() {
        let fields = FeedbackDraftGuideSupport.snapshot(original, submitting: false).fields
        #expect(fields.count == 8)
        #expect(fields["category"]?.value == .string("suggestion"))
        #expect(fields["detail_ready"]?.value == .bool(true))
        #expect(fields["steps_ready"]?.value == .bool(false))
        for (key, field) in fields {
            #expect(field.access == .readOnly)
            if key != "category", case .bool = field.value { continue }
            #expect(key == "category")
        }
        let request = FeedbackDraftGuideSupport.organizationRequest(for: original)
        #expect(request.contains(original.detail))
        #expect(request.contains("私下的备注"))
        #expect(!request.contains("之前填写的步骤"))
        let pageTools = FeedbackDraftGuideSupport.descriptor(pageID: pageID).tools
        #expect(pageTools.count == 1)
        #expect(pageTools.first?.definition.name == "propose_feedback_draft")
        #expect(pageTools.first?.access == .proposeChange)
        #expect(!GuideToolCatalog.knowledgeDefinitions.contains { $0.name == "propose_feedback_draft" })
    }

    @Test("预览只列出有效变更，确认后能逐字段撤销，包括未填栏及隐藏栏")
    func previewApplyUndo() throws {
        var edited = original
        let before = UUID(), after = UUID()
        let proposal = try FeedbackDraftGuideSupport.proposal(for: call(#"{"category":"bug","title":"保存失败","detail":"点保存后没有反应","reproduction_steps":"点保存","expected_behavior":"保存成功","actual_behavior":"没有反应","extra_context":"在手机上"}"#),
            draft: edited, pageID: pageID, revision: before)
        #expect(proposal.mutations.count == 7)
        #expect(edited == original)
        let result = try FeedbackDraftGuideSupport.apply(proposal, to: &edited, pageID: pageID, revision: before, nextRevision: after)
        #expect(edited == FeedbackDraft(category: .bug, title: "保存失败", detail: "点保存后没有反应",
            reproductionSteps: "点保存", expectedBehavior: "保存成功", actualBehavior: "没有反应", extraContext: "在手机上"))
        let undo = try #require(result.undoProposal)
        #expect(throws: GuideError.self) {
            try FeedbackDraftGuideSupport.apply(undo, to: &edited, pageID: pageID, revision: UUID(), nextRevision: UUID())
        }
        let restored = try FeedbackDraftGuideSupport.apply(undo, to: &edited, pageID: pageID, revision: after, nextRevision: UUID())
        #expect(edited == original)
        #expect(restored.undoProposal == nil)
    }

    @Test("保留未提及的字段，离页或继续编辑后不能确认旧预览")
    func partialChangesAndStalePreviews() throws {
        let version = UUID()
        var edited = original
        let proposal = try FeedbackDraftGuideSupport.proposal(for: call(#"{"category":"suggestion","title":"建议标题"}"#),
            draft: edited, pageID: pageID, revision: version)
        #expect(proposal.mutations.map(\.path) == ["title"])
        #expect(throws: GuideError.self) {
            try FeedbackDraftGuideSupport.apply(proposal, to: &edited, pageID: "feedback-center", revision: version, nextRevision: UUID())
        }
        #expect(throws: GuideError.self) {
            try FeedbackDraftGuideSupport.apply(proposal, to: &edited, pageID: pageID, revision: UUID(), nextRevision: UUID())
        }
        #expect(edited == original)
        _ = try FeedbackDraftGuideSupport.apply(proposal, to: &edited, pageID: pageID, revision: version, nextRevision: UUID())
        var expected = original
        expected.title = "建议标题"
        #expect(edited == expected)
    }

    @Test("拒绝空变更、类型错误、未知字段及建议类隐藏字段", arguments: [
        "{}", #"{"title":"  "}"#, #"{"category":"other"}"#, #"{"detail":42}"#, #"{"submit":true}"#,
        #"{"extra_context":null}"#, #"{"category":"suggestion"}"#, #"{"expected_behavior":"成功"}"#
    ])
    func invalidArguments(_ arguments: String) {
        #expect(throws: GuideError.self) {
            try FeedbackDraftGuideSupport.proposal(for: call(arguments), draft: original, pageID: pageID, revision: UUID())
        }
    }
}
