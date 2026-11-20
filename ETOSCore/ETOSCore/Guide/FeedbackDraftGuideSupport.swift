import Foundation

enum FeedbackDraftGuideSupport {
    static let toolName = "propose_feedback_draft"
    static let restoreToolName = "restore_feedback_draft"

    private enum Field: String, CaseIterable {
        case category, title, detail
        case steps = "reproduction_steps"
        case expected = "expected_behavior"
        case actual = "actual_behavior"
        case context = "extra_context"

        var label: String {
            switch self {
            case .category: NSLocalizedString("反馈类型", value: "Feedback Type", comment: "")
            case .title: NSLocalizedString("标题", value: "Title", comment: "")
            case .detail: NSLocalizedString("详细描述", value: "Description", comment: "")
            case .steps: NSLocalizedString("可复现步骤（可选）", value: "Steps to Reproduce (Optional)", comment: "")
            case .expected: NSLocalizedString("预期行为（可选）", value: "Expected Behavior (Optional)", comment: "")
            case .actual: NSLocalizedString("实际行为（可选）", value: "Actual Behavior (Optional)", comment: "")
            case .context: NSLocalizedString("补充信息（可选）", value: "Additional Information (Optional)", comment: "")
            }
        }

        var isBugDetail: Bool { self == .steps || self == .expected || self == .actual }

        func value(in draft: FeedbackDraft) -> String? {
            switch self {
            case .category: draft.category.rawValue
            case .title: draft.title
            case .detail: draft.detail
            case .steps: draft.reproductionSteps
            case .expected: draft.expectedBehavior
            case .actual: draft.actualBehavior
            case .context: draft.extraContext
            }
        }

        func set(_ text: String?, in draft: inout FeedbackDraft) throws {
            switch self {
            case .category:
                guard let text, let category = FeedbackCategory(rawValue: text) else { throw GuideError.invalidToolArguments }
                draft.category = category
            case .title: draft.title = text ?? ""
            case .detail: draft.detail = text ?? ""
            case .steps: draft.reproductionSteps = text
            case .expected: draft.expectedBehavior = text
            case .actual: draft.actualBehavior = text
            case .context: draft.extraContext = text
            }
        }
    }

    static func descriptor(pageID: GuidePageID) -> GuidePageDescriptor {
        var properties = Dictionary(uniqueKeysWithValues: Field.allCases.map {
            ($0.rawValue, JSONValue.dictionary(["type": .string("string")]))
        })
        properties["category"] = .dictionary(["type": .string("string"), "enum": .array([.string("bug"), .string("suggestion")])])
        let tool = InternalToolDefinition(name: toolName,
            description: NSLocalizedString("feedback.guide.tool", value: "When the user describes an issue or asks for help drafting feedback, suggest changes using only the details they shared. Omit unknown fields. Confirmation fills the local form. Only the user can submit it.", comment: "反馈草稿向导工具说明"),
            parameters: GuideToolCatalog.objectSchema(properties: properties))
        return GuidePageDescriptor(id: pageID, title: NSLocalizedString("新建反馈", value: "New Feedback", comment: ""),
            documents: [GuideDocumentReference(id: "feedback-assistant", title: NSLocalizedString("反馈助手", value: "Feedback", comment: ""))],
            tools: [GuidePageTool(definition: tool, access: .proposeChange)])
    }

    static func snapshot(_ draft: FeedbackDraft, submitting: Bool) -> GuidePageSnapshot {
        var fields = ["category": GuideSnapshotField(label: Field.category.label, value: .string(draft.category.rawValue), access: .readOnly),
                      "submitting": GuideSnapshotField(label: NSLocalizedString("提交中...", value: "Submitting…", comment: ""), value: .bool(submitting), access: .readOnly)]
        let readiness: [(Field, String)] = [(.title, "title_ready"), (.detail, "detail_ready"), (.steps, "steps_ready"),
                                            (.expected, "expected_ready"), (.actual, "actual_ready"), (.context, "context_ready")]
        for (field, key) in readiness {
            let filled = (!field.isBugDetail || draft.category == .bug) && field.value(in: draft)?.isEmpty == false
            fields[key] = GuideSnapshotField(label: field.label, value: .bool(filled), access: .readOnly)
        }
        return GuidePageSnapshot(fields: fields)
    }

    /// 仅在用户点表单整理按钮后构造消息。隐藏的 Bug 字段和未填写的项目均不随提问发送。
    static func organizationRequest(for draft: FeedbackDraft) -> String {
        var lines = [NSLocalizedString("feedback.guide.request", value: "Please organize my feedback into a draft for me to review. Use only the information below.", comment: "用户主动整理草稿的提问")]
        for field in Field.allCases where !field.isBugDetail || draft.category == .bug {
            let value = field == .category ? draft.category.localizedTitle : field.value(in: draft)
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("\(field.label)\n\(FeedbackTextSanitizer.redact(value))")
            }
        }
        return lines.joined(separator: "\n\n")
    }

    static func proposal(for call: InternalToolCall, draft: FeedbackDraft, pageID: GuidePageID, revision: UUID) throws -> GuideActionProposal {
        guard call.toolName == toolName else { throw GuideError.unsupportedTool(call.toolName) }
        let arguments = try GuideToolArguments.decode(call.arguments)
        try GuideToolArguments.requireOnlyKeys(Set(Field.allCases.map(\.rawValue)), in: arguments)
        var updated = draft
        var mutations: [GuideSettingMutation] = []
        var changes: [String: JSONValue] = [:]
        for field in Field.allCases {
            guard let text = try GuideToolArguments.optionalString(field.rawValue, in: arguments) else { continue }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !field.isBugDetail || updated.category == .bug else { throw GuideError.invalidToolArguments }
            guard value != field.value(in: draft) else { continue }
            try field.set(value, in: &updated)
            changes[field.rawValue] = .string(value)
            let preview = field == .category ? updated.category.localizedTitle : value
            mutations.append(GuideSettingMutation(path: field.rawValue, label: field.label, oldValue: nil, newValue: .string(preview)))
        }
        guard !mutations.isEmpty else { throw GuideError.invalidToolArguments }
        return GuideActionProposal(pageID: pageID, toolCallID: call.id, toolName: toolName,
            summary: NSLocalizedString("feedback.guide.preview", value: "Review these changes to your feedback draft. You can submit it from the form afterwards.", comment: "草稿确认预览"),
            mutations: mutations, arguments: ["revision": .string(revision.uuidString), "fields": .dictionary(changes)])
    }

    /// 版本绑定到这一份表单及其最近一次编辑。手工修改、重开同一页面后，旧预览与撤销均会失效。
    static func apply(_ proposal: GuideActionProposal, to draft: inout FeedbackDraft, pageID: GuidePageID,
                      revision: UUID, nextRevision: UUID) throws -> GuideActionExecution {
        guard proposal.pageID == pageID, proposal.arguments["revision"] == .string(revision.uuidString) else { throw GuideError.pageChanged }
        let restoring = proposal.toolName == restoreToolName
        guard restoring || proposal.toolName == toolName,
              case .dictionary(let values) = proposal.arguments["fields"] else { throw GuideError.invalidToolArguments }
        var updated = draft
        var previous: [String: JSONValue] = [:]
        for field in Field.allCases {
            previous[field.rawValue] = field.value(in: draft).map(JSONValue.string) ?? .null
            switch values[field.rawValue] {
            case .string(let text): try field.set(text, in: &updated)
            case .null where restoring: try field.set(nil, in: &updated)
            case nil where !restoring: continue
            default: throw GuideError.invalidToolArguments
            }
        }
        draft = updated
        let undoTitle = NSLocalizedString("feedback.guide.undo", value: "Restore the previous feedback draft", comment: "撤销反馈草稿修改")
        let undo = restoring ? nil : GuideActionProposal(pageID: pageID, toolCallID: "undo-\(proposal.toolCallID)", toolName: restoreToolName,
            summary: undoTitle, mutations: [], arguments: ["revision": .string(nextRevision.uuidString), "fields": .dictionary(previous)])
        let message = restoring
            ? NSLocalizedString("feedback.guide.restored", value: "Your previous feedback draft has been restored.", comment: "撤销反馈草稿后的结果")
            : NSLocalizedString("feedback.guide.applied", value: "Your draft is ready to review. Tap Submit on the form when you’re ready to share it.", comment: "反馈草稿确认结果")
        return GuideActionExecution(message: message, undoProposal: undo)
    }
}
