import Foundation
import Testing
@testable import ETOSCore

@Suite("思考扫光样式")
struct ThinkingSweepTests {
    @Test("只有启用彩虹的有效滑块到达最高档才使用彩虹扫光")
    func requiresEnabledRainbowSliderAtMaximum() {
        var control = ModelRequestBodyControl(
            id: "budget", title: "思考预算", kind: .optionGroup,
            defaultOptionID: "high", isSliderEnabled: true, usesRainbowAtMaximum: true,
            options: [
                .init(id: "low", title: "低", payload: ["budget": .int(0)]),
                .init(id: "high", title: "高", payload: ["budget": .int(100)])
            ]
        )
        let defaults = ModelRequestBodyControlState()
        #expect(ModelRequestBodyControlCompiler.usesRainbowThinkingSweep(controls: [control], state: defaults))

        var state = ModelRequestBodyControlState(selectedOptionIDsByControlID: [control.id: "low"])
        #expect(!ModelRequestBodyControlCompiler.usesRainbowThinkingSweep(controls: [control], state: state))
        state.selectedOptionIDsByControlID[control.id] = "high"
        state.sliderPositionsByControlID[control.id] = 0.9
        // 最近档位已是 high，但连续滑块仍未到端点，不能提前出现彩虹。
        #expect(!ModelRequestBodyControlCompiler.usesRainbowThinkingSweep(controls: [control], state: state))
        state.sliderPositionsByControlID[control.id] = 1
        #expect(ModelRequestBodyControlCompiler.usesRainbowThinkingSweep(controls: [control], state: state))

        control.usesRainbowAtMaximum = false
        #expect(!ModelRequestBodyControlCompiler.usesRainbowThinkingSweep(controls: [control], state: state))
        control.usesRainbowAtMaximum = true
        control.isEnabled = false
        #expect(!ModelRequestBodyControlCompiler.usesRainbowThinkingSweep(controls: [control], state: state))
        control.isEnabled = true
        control.isSliderEnabled = false
        #expect(!ModelRequestBodyControlCompiler.usesRainbowThinkingSweep(controls: [control], state: state))
        control.isSliderEnabled = true
        control.options.removeLast()
        #expect(!ModelRequestBodyControlCompiler.usesRainbowThinkingSweep(controls: [control], state: state))
        #expect(!ModelRequestBodyControlCompiler.usesRainbowThinkingSweep(controls: [], state: state))
    }

    @Test("最高档按当前选项顺序判定，不依赖参数值或档位名称")
    func maximumFollowsOptionOrder() {
        var control = ModelRequestBodyControl(
            id: "effort", title: "思考强度", kind: .optionGroup,
            defaultOptionID: "high", isSliderEnabled: true, usesRainbowAtMaximum: true,
            options: [
                .init(id: "low", title: "低", payload: ["effort": .string("low")]),
                .init(id: "high", title: "高", payload: ["effort": .string("high")])
            ]
        )
        let state = ModelRequestBodyControlState()
        #expect(ModelRequestBodyControlCompiler.usesRainbowThinkingSweep(controls: [control], state: state))
        control.options.append(.init(id: "max", title: "最大", payload: ["effort": .string("max")]))
        #expect(!ModelRequestBodyControlCompiler.usesRainbowThinkingSweep(controls: [control], state: state))
        control.options.swapAt(1, 2)
        #expect(ModelRequestBodyControlCompiler.usesRainbowThinkingSweep(controls: [control], state: state))
    }

    @Test("扫光快照变化会刷新气泡，但不会写入聊天历史")
    func appearanceSnapshotIsTransientAndStructural() throws {
        let plain = ChatMessage(role: .assistant, content: "")
        var rainbow = plain
        rainbow.usesRainbowThinkingSweep = true
        #expect(!ETStreamingMessageUpdatePolicy.isTextOnlyChange(from: plain, to: rainbow))
        #expect(!ETStreamingMessageUpdatePolicy.isTextOnlyChange(from: rainbow, to: plain))
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(rainbow))
        #expect(!restored.usesRainbowThinkingSweep)
    }
}

extension ChatServiceTests {
    @Test("扫光绑定实际请求模型，切换模型不修改旧请求，落盘不恢复样式")
    func thinkingSweepStaysWithRequestedMessage() async throws {
        let session = createPermanentTestSession(name: "请求扫光快照")
        let service = try #require(chatService)
        let previous = ChatMessage(role: .assistant, content: "历史回复")
        let pending = ChatMessage(role: .assistant, content: "")
        service.persistAndPublishMessages([previous, pending], for: session.id)
        let control = ModelRequestBodyControl(
            title: "思考强度", kind: .optionGroup, defaultOptionID: "high",
            isSliderEnabled: true, usesRainbowAtMaximum: true,
            options: [.init(id: "low", title: "低"), .init(id: "high", title: "高")]
        )
        let model = RunnableModel(
            provider: dummyModel.provider,
            model: Model(modelName: "rainbow-test", requestBodyControls: [control])
        )
        let usesRainbow = await service.prepareThinkingSweepAppearance(
            for: model, messageID: pending.id, sessionID: session.id
        )
        #expect(usesRainbow)
        service.selectedModelSubject.send(dummyModel)
        #expect(service.messagesSnapshot(for: session.id).first?.usesRainbowThinkingSweep == false)
        #expect(service.messagesSnapshot(for: session.id).last?.usesRainbowThinkingSweep == true)

        service.setMessageReceivingStream(true, messageID: pending.id, sessionID: session.id)
        #expect(service.messagesSnapshot(for: session.id).last?.usesRainbowThinkingSweep == true)
        await service.updateMessage(
            with: ChatMessage(role: .assistant, content: "回复完成"),
            for: pending.id, in: session.id
        )
        #expect(service.messagesSnapshot(for: session.id).last?.usesRainbowThinkingSweep == true)
        await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
        #expect(Persistence.loadMessages(for: session.id).last?.usesRainbowThinkingSweep == false)

        let nextPending = ChatMessage(role: .assistant, content: "")
        _ = try await service.appendConversationMessage(nextPending, to: session.id)
        let nextUsesRainbow = await service.prepareThinkingSweepAppearance(
            for: dummyModel, messageID: nextPending.id, sessionID: session.id
        )
        #expect(!nextUsesRainbow)
        #expect(service.messagesSnapshot(for: session.id).last?.usesRainbowThinkingSweep == false)
    }
}
