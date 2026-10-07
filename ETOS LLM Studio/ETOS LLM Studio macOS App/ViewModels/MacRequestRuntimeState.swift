import ETOSCore
import Foundation

struct MacRequestRuntimeSource: Sendable {
    let modelKey: String
    let sessionID: UUID?
    let title: String
    let controls: [ModelRequestBodyControl]
    let parameters: [String: JSONValue]

    init(model: RunnableModel, sessionID: UUID?) {
        modelKey = model.id; self.sessionID = sessionID; title = model.model.displayName
        controls = model.model.requestBodyControls; parameters = model.model.overrideParameters
    }
}

struct MacRequestRuntimeChange: Sendable, Equatable {
    enum Value: Sendable, Equatable { case toggle(Bool), option(String?), slider(Double) }
    let controlID: String
    let value: Value

    init(controlID: String, value: Value) { self.controlID = controlID; self.value = value }

    init(arguments: [String: JSONValue]) throws {
        try GuideToolArguments.requireOnlyKeys(["control_id", "active", "option_id", "position"], in: arguments)
        guard case .string(let id)? = arguments["control_id"], arguments.count == 2 else { throw GuideError.invalidToolArguments }
        controlID = id
        if case .bool(let value)? = arguments["active"] { self.value = .toggle(value) }
        else if case .string(let value)? = arguments["option_id"] { self.value = .option(value.isEmpty ? nil : value) }
        else if case .double(let value)? = arguments["position"] { self.value = .slider(value) }
        else if case .int(let value)? = arguments["position"] { self.value = .slider(Double(value)) }
        else { throw GuideError.invalidToolArguments }
    }

    /// 从最新数据库状态修改一项，不能用弹窗打开时的整份状态覆盖其他控制。
    func applying(to state: ModelRequestBodyControlState, controls: [ModelRequestBodyControl]) throws -> ModelRequestBodyControlState {
        guard let control = controls.first(where: { $0.id == controlID && $0.isEnabled }) else { throw GuideError.pageChanged }
        var result = state
        switch value {
        case .toggle(let active):
            guard control.kind == .toggle else { throw GuideError.invalidToolArguments }
            result.toggleValuesByControlID[controlID] = active
        case .option(let id):
            guard control.kind == .optionGroup,
                  id == nil || control.options.contains(where: { $0.id == id }) else { throw GuideError.invalidToolArguments }
            result.selectedOptionIDsByControlID[controlID] = id
            result.sliderPositionsByControlID.removeValue(forKey: controlID)
        case .slider(let position):
            guard control.isSliderEnabled, position.isFinite, (0...1).contains(position),
                  let descriptor = ModelRequestBodyControlSliderDescriptor(control: control) else { throw GuideError.invalidToolArguments }
            let settled = descriptor.restingPosition(for: position)
            result.sliderPositionsByControlID[controlID] = settled
            result.selectedOptionIDsByControlID[controlID] = descriptor.nearestOptionID(at: settled)
        }
        return ModelRequestBodyControlCompiler.normalized(result, for: controls)
    }
}

struct MacRequestRuntimeRow: Identifiable, Sendable {
    struct Option: Identifiable, Sendable { let id: String; let title: String }
    let id: String
    let title: String
    let kind: ModelRequestBodyControl.Kind
    let active: Bool
    let selectedOptionID: String
    let defaultOptionID: String
    let defaultSelectionTitle: String
    let options: [Option]
    let slider: ModelRequestBodyControlSliderDescriptor?
    let palette: RequestBodySliderPalette
    let usesRainbowAtMaximum: Bool
    let position: Double
    let valueLabel: String
}

struct MacRequestRuntimePresentation: Sendable {
    let rows: [MacRequestRuntimeRow]
    let preview: String
    let guideValues: JSONValue

    /// 包括滑块描述符、合并 JSON 和向导快照在内的遍历均在后台完成。
    init(source: MacRequestRuntimeSource, state: ModelRequestBodyControlState) {
        rows = source.controls.filter(\.isEnabled).map { control in
            let slider = control.isSliderEnabled ? ModelRequestBodyControlSliderDescriptor(control: control) : nil
            let position = slider?.position(in: state) ?? 0
            let defaultTitle = control.options.first(where: { $0.id == control.defaultOptionID })?.title
            return MacRequestRuntimeRow(id: control.id, title: control.title, kind: control.kind,
                active: state.toggleValuesByControlID[control.id] ?? control.defaultIsActive,
                selectedOptionID: state.selectedOptionIDsByControlID[control.id] ?? "",
                defaultOptionID: control.defaultOptionID ?? "",
                defaultSelectionTitle: defaultTitle.map { String(format: NSLocalizedString("跟随默认（%@）", comment: ""), $0) } ?? NSLocalizedString("跟随默认", comment: ""),
                options: control.options.map { .init(id: $0.id, title: $0.title) }, slider: slider,
                palette: RequestBodySliderPalette.resolved(for: control), usesRainbowAtMaximum: control.usesRainbowAtMaximum,
                position: position, valueLabel: slider?.displayValue(at: position) ?? "")
        }
        preview = ParameterExpressionParser.serializeRawJSONObject(parameters: ModelRequestBodyControlCompiler.effectiveOverrideParameters(
            base: source.parameters, controls: source.controls, state: state))
        // 任意 payload 可能带认证信息；向导只获得控件元数据和当前选择。
        guideValues = .array(rows.map { row in .dictionary([
            "id": .string(row.id), "title": .string(row.title), "kind": .string(row.kind.rawValue),
            "active": .bool(row.active), "option_id": .string(row.selectedOptionID),
            "default_option_id": .string(row.defaultOptionID),
            "slider_enabled": .bool(row.slider != nil), "position": .double(row.position),
            "rainbow_at_maximum": .bool(row.usesRainbowAtMaximum),
            "options": .array(row.options.map { .dictionary(["id": .string($0.id), "title": .string($0.title)]) })
        ]) })
    }
}
