import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacRequestRuntimeTests {
    @Test("当前选择逐项合并，选档清除滑块覆盖，回到默认保留其他控制")
    func changesPreserveOtherSelections() throws {
        let source = fixtureSource()
        var state = ModelRequestBodyControlState(toggleValuesByControlID: ["toggle": true])
        state = try MacRequestRuntimeChange(controlID: "level", value: .slider(0.54)).applying(to: state, controls: source.controls)
        #expect(state.toggleValuesByControlID["toggle"] == true)
        #expect(state.selectedOptionIDsByControlID["level"] == "high")
        let preview = MacRequestRuntimePresentation(source: source, state: state)
        let values = try ParameterExpressionParser.parseRawJSONObject(preview.preview)
        #expect(values["temperature"] == .double(0.5))
        #expect(values["nested"] == .dictionary(["base": .int(1), "toggle": .bool(true)]))
        state = try MacRequestRuntimeChange(controlID: "level", value: .option("low")).applying(to: state, controls: source.controls)
        #expect(state.sliderPositionsByControlID["level"] == nil)
        #expect(state.selectedOptionIDsByControlID["level"] == "low")
        state = try MacRequestRuntimeChange(controlID: "level", value: .option(nil)).applying(to: state, controls: source.controls)
        #expect(state.selectedOptionIDsByControlID["level"] == nil)
        #expect(state.toggleValuesByControlID["toggle"] == true)
        #expect(MacRequestRuntimePresentation(source: source, state: state).rows.last?.position == 1)
    }

    @Test("聊天向导仅包含控件元数据，基础参数及选项 payload 不进入快照")
    func guideCannotReadPayloadSecrets() throws {
        let source = fixtureSource()
        let prepared = MacRequestRuntimePresentation(source: source, state: .init())
        let json = try String(decoding: JSONEncoder().encode(prepared.guideValues), as: UTF8.self)
        #expect(!json.contains("secret-token"))
        #expect(!json.contains("api_key"))
        #expect(!json.contains("hidden-control"))
        #expect(json.contains("default_option_id"))
        #expect(prepared.preview.contains("secret-token"))
        #expect(prepared.rows.count == 2)
    }

    @Test("无效、禁用或类型不匹配的控制不能借向导写入")
    func validatesGuideChanges() throws {
        let controls = fixtureSource().controls
        for change in [MacRequestRuntimeChange(controlID: "missing", value: .toggle(true)),
                       .init(controlID: "hidden-control", value: .toggle(true)),
                       .init(controlID: "toggle", value: .option("low")),
                       .init(controlID: "level", value: .option("unknown")),
                       .init(controlID: "level", value: .slider(.infinity)),
                       .init(controlID: "level", value: .slider(-0.1))] {
            #expect(throws: GuideError.self) { try change.applying(to: .init(), controls: controls) }
        }
        #expect(throws: GuideError.self) { try MacRequestRuntimeChange(arguments: ["control_id": .string("toggle"), "active": .bool(true), "position": .int(1)]) }
        let reset = try MacRequestRuntimeChange(arguments: ["control_id": .string("level"), "option_id": .string("")])
        #expect(reset.value == .option(nil))
    }

    @MainActor
    @Test("切换模型、暂停及恢复等待已接受的写入，旧提案无法重放", .timeLimit(.minutes(1)))
    func writeBarrierAndRevision() async throws {
        let fixture = MacRuntimeStoreFixture(), gate = MacRuntimeWriteGate()
        let (started, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish() }
        let runtime = MacRequestRuntimeModel(store: .init(read: { await fixture.read($0) }, write: { state, source in
            signal.yield(())
            await gate.wait()
            await fixture.write(state, source: source)
        }))
        let first = fixtureModel(), second = fixtureModel(), session = UUID()
        runtime.select(first, sessionID: session)
        await runtime.waitForPendingWrites()
        let oldRevision = runtime.revision
        let writing = Task { try await runtime.apply(.init(controlID: "toggle", value: .toggle(true)), expectedRevision: oldRevision) }
        var events = started.makeAsyncIterator()
        _ = await events.next()
        writing.cancel()
        runtime.select(second, sessionID: UUID())
        #expect(runtime.presentation == nil)
        #expect(runtime.isWorking)
        #expect(await fixture.readKeys == [first.id, first.id])
        runtime.suspend()
        await gate.release()
        try await writing.value
        await runtime.waitForPendingWrites()
        #expect(await fixture.states[first.id]?.toggleValuesByControlID["toggle"] == true)
        #expect(runtime.presentation == nil)
        await #expect(throws: GuideError.self) { try await runtime.apply(.init(controlID: "toggle", value: .toggle(false)), expectedRevision: oldRevision) }
        // 模拟恢复后的数据库；恢复前排队的操作不能在此后覆盖它。
        await fixture.replace([second.id: .init(toggleValuesByControlID: ["toggle": false])])
        runtime.resume()
        await runtime.waitForPendingWrites()
        #expect(runtime.presentation?.rows.first?.active == false)
        #expect(!runtime.isWorking)
        await #expect(throws: GuideError.self) { try await runtime.apply(.init(controlID: "toggle", value: .toggle(false)), expectedRevision: oldRevision) }
    }

    @MainActor
    @Test("同一模型的配置刷新不会被仅比较 ID 的模型相等性吞掉")
    func forceRefreshUsesNewDefinitions() async {
        let runtime = MacRequestRuntimeModel(store: .init(read: { _ in .init() }, write: { _, _ in }))
        let first = fixtureModel(), session = UUID()
        runtime.select(first, sessionID: session)
        await runtime.waitForPendingWrites()
        var updated = first.model
        updated.requestBodyControls[0].defaultIsActive = true
        runtime.select(.init(provider: first.provider, model: updated), sessionID: session, force: true)
        await runtime.waitForPendingWrites()
        #expect(runtime.presentation?.rows.first?.active == true)
    }

    private func fixtureSource() -> MacRequestRuntimeSource { .init(model: fixtureModel(), sessionID: UUID()) }

    private func fixtureModel() -> RunnableModel {
        let controls: [ModelRequestBodyControl] = [
            .init(id: "toggle", title: "嵌套开关", kind: .toggle, payload: ["nested": .dictionary(["toggle": .bool(true)])]),
            .init(id: "hidden-control", title: "禁用", kind: .toggle, isEnabled: false, defaultIsActive: true, payload: ["temperature": .int(99)]),
            .init(id: "level", title: "温度", kind: .optionGroup, defaultOptionID: "high", isSliderEnabled: true, sliderGranularity: 0.1,
                  options: [.init(id: "low", title: "低", payload: ["temperature": .int(0)]), .init(id: "high", title: "高", payload: ["temperature": .int(1)])])
        ]
        let model = Model(modelName: "测试模型", overrideParameters: ["api_key": .string("secret-token"), "nested": .dictionary(["base": .int(1)])], requestBodyControls: controls)
        return .init(provider: .init(name: "测试提供商", baseURL: "https://example.invalid", apiKeys: [], apiFormat: "openai-compatible"), model: model)
    }
}

private actor MacRuntimeStoreFixture {
    private(set) var states: [String: ModelRequestBodyControlState] = [:]
    private(set) var readKeys: [String] = []
    func read(_ source: MacRequestRuntimeSource) -> ModelRequestBodyControlState { readKeys.append(source.modelKey); return states[source.modelKey] ?? .init() }
    func write(_ state: ModelRequestBodyControlState, source: MacRequestRuntimeSource) { states[source.modelKey] = state }
    func replace(_ value: [String: ModelRequestBodyControlState]) { states = value }
}

private actor MacRuntimeWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
