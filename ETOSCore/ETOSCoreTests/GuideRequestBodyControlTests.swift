import Foundation
import Testing
@testable import ETOSCore

extension GuideInfrastructureTests {
    @Test("文档中的控制示例可直接生成提案并编译请求参数", arguments: [
        GuideRequestBodyControlKnowledge.reasoningExample,
        GuideRequestBodyControlKnowledge.thinkingOffExample,
        GuideRequestBodyControlKnowledge.sliderExample,
        GuideRequestBodyControlKnowledge.customExample
    ])
    func requestControlExamplesAreExecutable(_ arguments: String) throws {
        let retained = ModelRequestBodyControl(title: "保留控制", kind: .toggle, defaultIsActive: true, payload: ["top_p": .double(1.0)])
        let original = [retained]
        let state = ModelRequestBodyControlState()
        let proposal = try requestControlProposal(arguments, controls: original, state: state)
        #expect(original == [retained])
        let applied = try GuideModelRequestBodyControls.apply(proposal, controls: original, state: state)
        #expect(applied.controls.count == 2)
        #expect(applied.controls.first == retained)
        let parameters = ModelRequestBodyControlCompiler.effectiveOverrideParameters(base: [:], controls: applied.controls, state: applied.state)
        #expect(parameters["top_p"] == .double(1.0))
        switch arguments {
        case GuideRequestBodyControlKnowledge.reasoningExample:
            #expect(parameters["reasoning_effort"] == .string("medium"))
        case GuideRequestBodyControlKnowledge.thinkingOffExample:
            #expect(parameters["thinking"] == .dictionary(["type": .string("disabled")]))
        case GuideRequestBodyControlKnowledge.sliderExample:
            #expect(parameters["temperature"] == .double(0.5))
        default:
            #expect(parameters["vendor_config"] == .dictionary([
                "search": .dictionary(["enabled": .bool(true)]),
                "response": .dictionary(["format": .string("json")])
            ]))
        }
        // 提案内的新增 ID 已固定，确认时不能重新分配；撤销精确恢复配置和当前选择。
        let repeated = try GuideModelRequestBodyControls.apply(proposal, controls: original, state: state)
        #expect(applied.controls == repeated.controls)
        let undo = try #require(applied.undoProposal)
        let restored = try GuideModelRequestBodyControls.apply(undo, controls: applied.controls, state: applied.state)
        #expect(restored.controls == original)
        #expect(restored.state == state)
        #expect(restored.undoProposal == nil)
    }

    @Test("增量修改保留未指定配置、隐藏秘密和用户新写入的秘密")
    func requestControlUpdatesPreserveSecrets() throws {
        let control = ModelRequestBodyControl(id: "custom", title: "旧名称", kind: .toggle, defaultIsActive: true, payload: [
            "headers": .dictionary(["Authorization": .string("private-old-value")]),
            "vendor": .dictionary(["secret": .string("nested-old-value"), "mode": .string("old")]),
            "temperature": .double(0.8)
        ])
        let state = ModelRequestBodyControlState(toggleValuesByControlID: [control.id: false])
        let renamed = try requestControlProposal(#"{"controls":[{"id":"custom","title":"新名称"}]}"#, controls: [control], state: state)
        let renameResult = try GuideModelRequestBodyControls.apply(renamed, controls: [control], state: state)
        #expect(renameResult.controls[0].payload == control.payload)
        #expect(renameResult.state == state)

        let replaced = try requestControlProposal(#"{"controls":[{"id":"custom","payload":{"headers":{"Authorization":"<hidden>"},"vendor":{"mode":"new"},"temperature":0.2}}]}"#, controls: [control], state: state)
        let replacement = try GuideModelRequestBodyControls.apply(replaced, controls: [control], state: state)
        #expect(replacement.controls[0].payload["headers"] == control.payload["headers"])
        #expect(replacement.controls[0].payload["vendor"] == .dictionary(["secret": .string("nested-old-value"), "mode": .string("new")]))
        let fresh = try requestControlProposal(#"{"controls":[{"id":"custom","payload":{"headers":{"Authorization":"private-new-value"}}}]}"#, controls: [control], state: state)
        let freshResult = try GuideModelRequestBodyControls.apply(fresh, controls: [control], state: state)
        #expect(freshResult.controls[0].payload["headers"] == .dictionary(["Authorization": .string("private-new-value")]))
        let preview = try JSONEncoder().encode(fresh.mutations)
        let fields = GuideModelRequestBodyControls.snapshotFields(controls: [control], state: state, base: ["api_key": .string("base-secret")])
        let snapshot = try JSONEncoder().encode(GuidePageSnapshot(fields: fields))
        let visible = String(decoding: preview + snapshot, as: UTF8.self)
        for secret in ["private-old-value", "nested-old-value", "private-new-value", "base-secret"] {
            #expect(!visible.contains(secret))
        }
        #expect(visible.contains(GuideSnapshotField.hiddenValue))
    }

    @Test("组选项修改沿用 ID 并保留秘密，滑块颜色和粒度正确归一化")
    func requestControlOptionUpdatesPreserveIdentity() throws {
        let control = ModelRequestBodyControl(
            id: "group", title: "组选项", kind: .optionGroup, defaultOptionID: "first",
            options: [
                ModelRequestBodyControlOption(id: "first", title: "第一档", payload: ["api_key": .string("option-private"), "budget": .int(10)]),
                ModelRequestBodyControlOption(id: "second", title: "第二档", payload: ["budget": .int(20)])
            ]
        )
        let state = ModelRequestBodyControlState(selectedOptionIDsByControlID: ["group": "second"])
        let proposal = try requestControlProposal(#"{"controls":[{"id":"group","options":[{"id":"second","title":"高","payload":{"budget":20}},{"id":"first","title":"低","payload":{"budget":10}}],"slider_enabled":true,"slider_granularity":0.5,"slider_start_color":"#aabbcc","slider_end_color":"11223344","rainbow_at_maximum":true}]}"#, controls: [control], state: state)
        let applied = try GuideModelRequestBodyControls.apply(proposal, controls: [control], state: state)
        #expect(applied.controls[0].defaultOptionID == "first")
        #expect(applied.controls[0].options.map(\.id) == ["second", "first"])
        #expect(applied.controls[0].options[1].payload["api_key"] == .string("option-private"))
        #expect(applied.controls[0].sliderGranularity == 0.5)
        #expect(applied.controls[0].sliderStartColorHex == "AABBCCFF")
        #expect(applied.controls[0].sliderEndColorHex == "11223344")
        #expect(applied.controls[0].usesRainbowAtMaximum)
        #expect(applied.state == state)
        #expect(!String(decoding: try JSONEncoder().encode(proposal.mutations), as: UTF8.self).contains("option-private"))
    }

    @Test("只删除显式指定的控制并可撤销恢复运行态")
    func requestControlDeletionIsExplicit() throws {
        let kept = ModelRequestBodyControl(id: "keep", title: "保留", kind: .toggle)
        let removed = ModelRequestBodyControl(id: "remove", title: "移除", kind: .toggle)
        let state = ModelRequestBodyControlState(toggleValuesByControlID: ["keep": true, "remove": true])
        let proposal = try requestControlProposal(#"{"remove_control_ids":["remove"]}"#, controls: [kept, removed], state: state)
        let applied = try GuideModelRequestBodyControls.apply(proposal, controls: [kept, removed], state: state)
        #expect(applied.controls == [kept])
        #expect(applied.state.toggleValuesByControlID == ["keep": true])
        let undo = try #require(applied.undoProposal)
        let restored = try GuideModelRequestBodyControls.apply(undo, controls: applied.controls, state: applied.state)
        #expect(restored.controls == [kept, removed])
        #expect(restored.state == state)
    }

    @Test("默认档位不覆盖当前选择，显式选择会清除旧滑块位置")
    func requestControlDefaultsAndCurrentSelectionAreDistinct() throws {
        let control = ModelRequestBodyControl(
            id: "effort", title: "强度", kind: .optionGroup, defaultOptionID: "low", isSliderEnabled: true,
            options: [
                ModelRequestBodyControlOption(id: "low", title: "低", payload: ["budget": .int(0)]),
                ModelRequestBodyControlOption(id: "high", title: "高", payload: ["budget": .int(100)])
            ]
        )
        let state = ModelRequestBodyControlState(selectedOptionIDsByControlID: ["effort": "low"], sliderPositionsByControlID: ["effort": 0.25])
        let defaultProposal = try requestControlProposal(#"{"controls":[{"id":"effort","default_option_id":"high"}]}"#, controls: [control], state: state)
        let defaults = try GuideModelRequestBodyControls.apply(defaultProposal, controls: [control], state: state)
        #expect(defaults.state == state)
        let currentProposal = try requestControlProposal(#"{"controls":[{"id":"effort","current_option_id":"high"}]}"#, controls: [control], state: state)
        let current = try GuideModelRequestBodyControls.apply(currentProposal, controls: [control], state: state)
        #expect(current.state.selectedOptionIDsByControlID["effort"] == "high")
        #expect(current.state.sliderPositionsByControlID["effort"] == nil)
        #expect(ModelRequestBodyControlCompiler.effectiveOverrideParameters(base: [:], controls: current.controls, state: current.state)["budget"] == .int(100))
        let reset = try requestControlProposal(#"{"controls":[{"id":"effort","current_option_id":""}]}"#, controls: [control], state: state)
        let resetResult = try GuideModelRequestBodyControls.apply(reset, controls: [control], state: state)
        #expect(resetResult.state.isEmpty)
    }

    @Test("配置或当前选择已改变时不能应用旧提案和旧撤销")
    func requestControlProposalsRejectStaleState() throws {
        let control = ModelRequestBodyControl(id: "switch", title: "开关", kind: .toggle)
        let proposal = try requestControlProposal(#"{"controls":[{"id":"switch","current_active":true}]}"#, controls: [control])
        var changed = control
        changed.title = "用户改名"
        #expect(throws: GuideError.self) { try GuideModelRequestBodyControls.apply(proposal, controls: [changed], state: .init()) }
        #expect(throws: GuideError.self) {
            try GuideModelRequestBodyControls.apply(proposal, controls: [control], state: .init(toggleValuesByControlID: ["switch": true]))
        }
        let applied = try GuideModelRequestBodyControls.apply(proposal, controls: [control], state: .init())
        let undo = try #require(applied.undoProposal)
        #expect(throws: GuideError.self) { try GuideModelRequestBodyControls.apply(undo, controls: [changed], state: applied.state) }
    }

    @Test("拒绝未知控制、重复 ID、非法选项和无效滑块参数", arguments: [
        #"{"controls":[{"id":"missing","title":"不存在"}]}"#,
        #"{"remove_control_ids":["missing"]}"#,
        #"{"controls":[{"title":"","kind":"toggle"}]}"#,
        #"{"controls":[{"title":"未知类型","kind":"unknown"}]}"#,
        #"{"controls":[{"title":"组选项","kind":"optionGroup","options":[{"id":"x","title":"甲","payload":{}},{"id":"x","title":"乙","payload":{}}]}]}"#,
        #"{"controls":[{"title":"组选项","kind":"optionGroup","default_option_id":"missing"}]}"#,
        #"{"controls":[{"title":"滑块","kind":"optionGroup","slider_enabled":true,"options":[]}]}"#,
        #"{"controls":[{"title":"滑块","kind":"optionGroup","slider_granularity":0}]}"#,
        #"{"controls":[{"title":"滑块","kind":"optionGroup","slider_start_color":"invalid"}]}"#,
        #"{"controls":[{"title":"开关","kind":"toggle","current_slider_position":2}]}"#,
        #"{"controls":[{"title":"组选项","kind":"optionGroup","current_option_id":"","current_slider_position":0.5}]}"#,
        #"{"controls":[{"id":"switch","title":"甲"},{"id":"switch","title":"乙"}]}"#,
        #"{"controls":[{"id":"switch","title":"甲"}],"remove_control_ids":["switch"]}"#
    ])
    func requestControlValidation(_ arguments: String) {
        let control = ModelRequestBodyControl(id: "switch", title: "开关", kind: .toggle)
        #expect(throws: GuideError.self) { try requestControlProposal(arguments, controls: [control]) }
    }

    @Test("自然语言思考问题可检索结构化控制文档且文档说明源码按行读取")
    func requestControlKnowledgeIsDiscoverable() async throws {
        let chinese = GuideRequestBodyControlKnowledge.document(locale: Locale(identifier: "zh-Hans"))
        let english = GuideRequestBodyControlKnowledge.document(locale: Locale(identifier: "en"))
        let service = GuideKnowledgeService(documents: [chinese])
        for query in ["怎么调整思考强度", "帮我关闭思考", "我要设置推理预算", "reasoning effort"] {
            #expect(await service.search(query).contains { $0.id == chinese.id })
        }
        for document in [chinese, english] {
            #expect(document.content.contains("search_source_code"))
            #expect(document.content.contains("read_source_file(path,start_line,end_line)"))
            #expect(document.content.contains("240"))
            #expect(document.content.contains("current_option_id"))
        }
    }

    @MainActor
    @Test("只有模型相关编辑页自动携带详细控制知识，两条模型线路一致", arguments: [true, false])
    func requestControlGuidanceFollowsDeclaredPage(includesSystem: Bool) throws {
        let root = GuidePageDescriptor(id: "settings-root", title: "设置")
        let editor = GuidePageDescriptor(id: "model-configuration", title: "模型信息", documents: [
            GuideDocumentReference(id: "model-request-body", title: "请求体")
        ])
        let chinese = Locale(identifier: "zh-Hans")
        let brief = GuideRequestBodyControlKnowledge.orientation(for: root, locale: chinese)
        #expect(brief.contains("结构化控制"))
        #expect(!brief.contains("current_option_id"))
        #expect(!brief.contains("reasoning_effort"))
        #expect(!brief.contains("propose_model_request_body_controls"))
        for page in [root, editor] {
            let messages = GuidePromptBuilder.requestMessages(
                history: [ChatMessage(role: .user, content: "怎么改参数")],
                context: GuidePageContext(descriptor: page, snapshot: .empty),
                includesClientSystemPrompt: includesSystem
            )
            let context = try #require(messages.first { $0.content.contains("<guide_runtime_context") })
            #expect(context.content.contains("current_option_id") == (page.id == editor.id))
            #expect(messages.contains { $0.role == .system } == includesSystem)
        }
        #expect(!GuideToolCatalog.knowledgeDefinitions.contains { $0.name == GuideModelRequestBodyControls.toolDefinition.name })
    }
}

private func requestControlProposal(
    _ arguments: String,
    controls: [ModelRequestBodyControl] = [],
    state: ModelRequestBodyControlState = .init()
) throws -> GuideActionProposal {
    try GuideModelRequestBodyControls.buildProposal(
        call: InternalToolCall(id: "controls", toolName: GuideModelRequestBodyControls.toolDefinition.name, arguments: arguments),
        pageID: "model-editor", controls: controls,
        snapshot: GuidePageSnapshot(fields: GuideModelRequestBodyControls.snapshotFields(controls: controls, state: state, base: [:]))
    )
}
