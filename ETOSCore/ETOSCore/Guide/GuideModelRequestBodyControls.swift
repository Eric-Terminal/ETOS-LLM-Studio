import Foundation

/// 结构化控制的模型页边界：只改明确指定的控制，提案持有实际执行值，预览和模型快照始终脱敏。
public enum GuideModelRequestBodyControls {
    public static let restoreToolName = "restore_model_request_body_controls"

    public struct Application: Sendable {
        public let controls: [ModelRequestBodyControl]
        public let state: ModelRequestBodyControlState
        public let undoProposal: GuideActionProposal?
    }

    public static func snapshotFields(
        controls: [ModelRequestBodyControl],
        state: ModelRequestBodyControlState,
        base: [String: JSONValue]
    ) -> [String: GuideSnapshotField] {
        [
            "request_body_controls": GuideSnapshotField(
                label: NSLocalizedString("结构化控制", comment: "模型向导控制列表"),
                value: .array(controls.map(controlValue))
            ),
            "request_body_control_state": GuideSnapshotField(
                label: NSLocalizedString("控制项当前状态", value: "Current Control State", comment: "模型向导运行态"),
                value: stateValue(state), access: .readOnly
            ),
            "effective_request_body_overrides": GuideSnapshotField(
                label: NSLocalizedString("当前有效请求参数", value: "Effective Request Overrides", comment: "模型向导实际覆盖参数"),
                value: .dictionary(ModelRequestBodyControlCompiler.effectiveOverrideParameters(base: base, controls: controls, state: state)),
                access: .readOnly
            )
        ]
    }

    public static func buildProposal(
        call: InternalToolCall,
        pageID: GuidePageID,
        controls: [ModelRequestBodyControl],
        snapshot: GuidePageSnapshot
    ) throws -> GuideActionProposal {
        guard call.toolName == toolDefinition.name,
              let stateValue = snapshot.fields["request_body_control_state"]?.value else {
            throw GuideError.invalidToolArguments
        }
        guard snapshot.fields["request_body_controls"]?.value == GuideSecretRedactor.redact(.array(controls.map(controlValue))) else {
            throw GuideError.pageChanged
        }
        let state: ModelRequestBodyControlState = try decode(stateValue)
        let arguments = try GuideToolArguments.decode(call.arguments)
        try GuideToolArguments.requireOnlyKeys(["controls", "remove_control_ids"], in: arguments)
        let drafts = try array(arguments["controls"])
        let removed = try array(arguments["remove_control_ids"]).map { value -> String in
            guard case .string(let id) = value else { throw GuideError.invalidToolArguments }
            return id
        }
        guard !drafts.isEmpty || !removed.isEmpty,
              Set(removed).count == removed.count,
              removed.allSatisfy({ id in controls.contains { $0.id == id } }) else {
            throw GuideError.invalidToolArguments
        }

        var updated = controls.filter { !removed.contains($0.id) }
        var updatedState = state
        var touchedIDs = Set(removed)
        for draft in drafts {
            guard case .dictionary(let fields) = draft else { throw GuideError.invalidToolArguments }
            let id = try GuideToolArguments.optionalString("id", in: fields)
            let index = id.flatMap { id in updated.firstIndex { $0.id == id } }
            // 新增省略控制 ID，客户端只在生成提案时分配一次；未知 ID 不能悄悄新增。
            guard id == nil || index != nil else { throw GuideError.invalidToolArguments }
            let control = try patchedControl(fields, existing: index.map { updated[$0] })
            guard touchedIDs.insert(control.id).inserted else { throw GuideError.invalidToolArguments }
            try updateCurrentState(&updatedState, fields: fields, control: control)
            if let index { updated[index] = control } else { updated.append(control) }
        }
        updatedState = ModelRequestBodyControlCompiler.normalized(updatedState, for: updated)
        var mutations = (controls + updated.filter { new in !controls.contains { $0.id == new.id } }).compactMap { control -> GuideSettingMutation? in
            let old = controls.first { $0.id == control.id }
            let new = updated.first { $0.id == control.id }
            guard old != new else { return nil }
            return GuideSettingMutation(
                path: "request_body_controls.\(control.id)", label: new?.title ?? control.title,
                oldValue: old.map { GuideSecretRedactor.redact(controlValue($0)) },
                newValue: new.map { GuideSecretRedactor.redact(controlValue($0)) } ?? .null
            )
        }
        if state != updatedState {
            mutations.append(GuideSettingMutation(
                path: "request_body_control_state",
                label: NSLocalizedString("控制项当前状态", value: "Current Control State", comment: "模型向导运行态"),
                oldValue: self.stateValue(state), newValue: self.stateValue(updatedState)
            ))
        }
        guard !mutations.isEmpty else { throw GuideError.invalidToolArguments }
        let summary = GuideSecretRedactor.containsSensitiveField(.dictionary(arguments))
            ? NSLocalizedString("修改结构化控制（包含疑似认证字段，请仔细确认）", value: "Modify structured controls (may contain credentials; review carefully)", comment: "向导敏感控制提案")
            : NSLocalizedString("修改结构化控制", value: "Modify Structured Controls", comment: "向导控制提案")
        return GuideActionProposal(
            pageID: pageID, toolCallID: call.id, toolName: call.toolName, summary: summary,
            mutations: mutations,
            arguments: [
                "expected_controls": storedControlsValue(controls), "controls": storedControlsValue(updated),
                "expected_state": self.stateValue(state), "state": self.stateValue(updatedState)
            ]
        )
    }

    public static func apply(
        _ proposal: GuideActionProposal,
        controls: [ModelRequestBodyControl],
        state: ModelRequestBodyControlState
    ) throws -> Application {
        guard proposal.toolName == toolDefinition.name || proposal.toolName == restoreToolName,
              let expectedControlsValue = proposal.arguments["expected_controls"],
              let expectedStateValue = proposal.arguments["expected_state"],
              let controlsValue = proposal.arguments["controls"],
              let newStateValue = proposal.arguments["state"] else {
            throw GuideError.invalidToolArguments
        }
        let expectedControls = try storedControls(from: expectedControlsValue)
        let expectedState: ModelRequestBodyControlState = try decode(expectedStateValue)
        guard controls == expectedControls, state == expectedState else { throw GuideError.pageChanged }
        let updated = try storedControls(from: controlsValue)
        let updatedState: ModelRequestBodyControlState = try decode(newStateValue)
        let undo = proposal.toolName == restoreToolName ? nil : GuideActionProposal(
            pageID: proposal.pageID, toolCallID: "undo-\(proposal.toolCallID)", toolName: restoreToolName,
            summary: NSLocalizedString("撤销上次修改", comment: "向导控制撤销摘要"), mutations: [],
            arguments: [
                "expected_controls": controlsValue, "controls": expectedControlsValue,
                "expected_state": newStateValue, "state": expectedStateValue
            ]
        )
        return Application(controls: updated, state: updatedState, undoProposal: undo)
    }

    private static func patchedControl(_ fields: [String: JSONValue], existing: ModelRequestBodyControl?) throws -> ModelRequestBodyControl {
        try GuideToolArguments.requireOnlyKeys(Set(controlProperties.keys), in: fields)
        let title = try GuideToolArguments.optionalString("title", in: fields)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: ModelRequestBodyControl.Kind?
        if let raw = try GuideToolArguments.optionalString("kind", in: fields) {
            guard let parsed = ModelRequestBodyControl.Kind(rawValue: raw) else { throw GuideError.invalidToolArguments }
            kind = parsed
        } else { kind = nil }
        guard title != "", existing != nil || (title != nil && kind != nil) else { throw GuideError.invalidToolArguments }
        var control: ModelRequestBodyControl
        if let existing { control = existing }
        else if let title, let kind { control = ModelRequestBodyControl(title: title, kind: kind) }
        else { throw GuideError.invalidToolArguments }
        // 类型转换会丢弃另一类控制的配置，要求使用明确的删除和新增提案。
        guard kind == nil || kind == control.kind else { throw GuideError.invalidToolArguments }
        if let title { control.title = title }
        if let value = try GuideToolArguments.optionalBool("enabled", in: fields) { control.isEnabled = value }
        switch control.kind {
        case .toggle:
            guard Set(fields.keys).isDisjoint(with: optionOnlyKeys) else { throw GuideError.invalidToolArguments }
            if let value = try GuideToolArguments.optionalBool("default_active", in: fields) { control.defaultIsActive = value }
            if let payload = fields["payload"] {
                control.payload = try GuideRequestBodyControlSettingsSupport.payload(from: preservingSecrets(payload, existing: .dictionary(control.payload)))
            }
        case .optionGroup:
            guard Set(fields.keys).isDisjoint(with: ["payload", "default_active", "current_active"]) else { throw GuideError.invalidToolArguments }
            if let options = fields["options"] {
                var updated = try GuideRequestBodyControlSettingsSupport.options(from: options)
                for index in updated.indices {
                    if let old = control.options.first(where: { $0.id == updated[index].id }) {
                        updated[index].payload = try GuideRequestBodyControlSettingsSupport.payload(from: preservingSecrets(.dictionary(updated[index].payload), existing: .dictionary(old.payload)))
                    }
                }
                control.options = updated
                if let id = control.defaultOptionID, !updated.contains(where: { $0.id == id }) { control.defaultOptionID = nil }
            }
            if let id = try GuideToolArguments.optionalString("default_option_id", in: fields) {
                guard id.isEmpty || control.options.contains(where: { $0.id == id }) else { throw GuideError.invalidToolArguments }
                control.defaultOptionID = id.isEmpty ? nil : id
            }
            if let value = try GuideToolArguments.optionalBool("slider_enabled", in: fields) { control.isSliderEnabled = value }
            if let value = fields["slider_granularity"] { control.sliderGranularity = try GuideRequestBodyControlSettingsSupport.optionalPositiveNumber(from: value) }
            if let value = fields["slider_start_color"] { control.sliderStartColorHex = try GuideRequestBodyControlSettingsSupport.optionalColor(from: value) }
            if let value = fields["slider_end_color"] { control.sliderEndColorHex = try GuideRequestBodyControlSettingsSupport.optionalColor(from: value) }
            if let value = try GuideToolArguments.optionalBool("rainbow_at_maximum", in: fields) { control.usesRainbowAtMaximum = value }
            guard !control.isSliderEnabled || control.options.count >= 2 else { throw GuideError.invalidToolArguments }
        }
        return control
    }

    private static func updateCurrentState(_ state: inout ModelRequestBodyControlState, fields: [String: JSONValue], control: ModelRequestBodyControl) throws {
        if let value = try GuideToolArguments.optionalBool("current_active", in: fields) { state.toggleValuesByControlID[control.id] = value }
        if let id = try GuideToolArguments.optionalString("current_option_id", in: fields) {
            guard id.isEmpty || control.options.contains(where: { $0.id == id }) else { throw GuideError.invalidToolArguments }
            state.selectedOptionIDsByControlID[control.id] = id.isEmpty ? nil : id
            // 显式选择档位时丢弃旧滑块位置，否则位置会优先于所选档位。
            state.sliderPositionsByControlID[control.id] = nil
        }
        if let value = fields["current_slider_position"] {
            let position: Double
            switch value {
            case .double(let number): position = number
            case .int(let number): position = Double(number)
            default: throw GuideError.invalidToolArguments
            }
            guard fields["current_option_id"] == nil, position.isFinite, (0...1).contains(position),
                  control.isSliderEnabled, let descriptor = ModelRequestBodyControlSliderDescriptor(control: control) else {
                throw GuideError.invalidToolArguments
            }
            state.sliderPositionsByControlID[control.id] = position
            state.selectedOptionIDsByControlID[control.id] = descriptor.nearestOptionID(at: position)
        }
    }

    /// 已隐藏的秘密不能因模型回传占位符或省略字段而丢失；显式提供新值仍可覆盖。
    private static func preservingSecrets(_ proposed: JSONValue, existing: JSONValue) -> JSONValue {
        if proposed == .string(GuideSnapshotField.hiddenValue) { return existing }
        if case .array(let items) = proposed, case .array(let old) = existing {
            return .array(items.enumerated().map { index, item in
                old.indices.contains(index) ? preservingSecrets(item, existing: old[index]) : item
            })
        }
        guard case .dictionary(var updated) = proposed, case .dictionary(let old) = existing else { return proposed }
        for (key, value) in old {
            if let replacement = updated[key] {
                updated[key] = preservingSecrets(replacement, existing: value)
            } else if GuideSecretRedactor.containsSensitiveField(.dictionary([key: value])) {
                updated[key] = value
            }
        }
        return .dictionary(updated)
    }

    private static func controlValue(_ control: ModelRequestBodyControl) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(control.id), "title": .string(control.title), "kind": .string(control.kind.rawValue),
            "enabled": .bool(control.isEnabled)
        ]
        switch control.kind {
        case .toggle:
            fields["default_active"] = .bool(control.defaultIsActive)
            fields["payload"] = .dictionary(control.payload)
        case .optionGroup:
            fields["default_option_id"] = .string(control.defaultOptionID ?? "")
            fields["slider_enabled"] = .bool(control.isSliderEnabled)
            fields["slider_granularity"] = GuideRequestBodyControlSettingsSupport.optionalPositiveNumberValue(control.sliderGranularity)
            fields["slider_start_color"] = .string(control.sliderStartColorHex ?? "")
            fields["slider_end_color"] = .string(control.sliderEndColorHex ?? "")
            fields["rainbow_at_maximum"] = .bool(control.usesRainbowAtMaximum)
            fields["options"] = GuideRequestBodyControlSettingsSupport.optionsValue(control.options)
        }
        return .dictionary(fields)
    }

    private static func stateValue(_ state: ModelRequestBodyControlState) -> JSONValue {
        .dictionary([
            "toggleValuesByControlID": .dictionary(state.toggleValuesByControlID.mapValues(JSONValue.bool)),
            "selectedOptionIDsByControlID": .dictionary(state.selectedOptionIDsByControlID.mapValues(JSONValue.string)),
            "sliderPositionsByControlID": .dictionary(state.sliderPositionsByControlID.mapValues(JSONValue.double))
        ])
    }

    private static func array(_ value: JSONValue?) throws -> [JSONValue] {
        guard let value else { return [] }
        guard case .array(let items) = value else { throw GuideError.invalidToolArguments }
        return items
    }

    /// 内存撤销不能经过 JSON 文本往返，否则 payload 中 double(1) 会变成 int(1)，破坏精确恢复和冲突判断。
    private static func storedControlsValue(_ controls: [ModelRequestBodyControl]) -> JSONValue {
        .array(controls.map { control in
            .dictionary([
                "id": .string(control.id), "title": .string(control.title), "kind": .string(control.kind.rawValue),
                "enabled": .bool(control.isEnabled), "default_active": .bool(control.defaultIsActive),
                "default_option_id": control.defaultOptionID.map(JSONValue.string) ?? .null,
                "slider_enabled": .bool(control.isSliderEnabled),
                "slider_granularity": control.sliderGranularity.map(JSONValue.double) ?? .null,
                "slider_start_color": control.sliderStartColorHex.map(JSONValue.string) ?? .null,
                "slider_end_color": control.sliderEndColorHex.map(JSONValue.string) ?? .null,
                "rainbow_at_maximum": .bool(control.usesRainbowAtMaximum),
                "payload": .dictionary(control.payload),
                "options": GuideRequestBodyControlSettingsSupport.optionsValue(control.options)
            ])
        })
    }

    private static func storedControls(from value: JSONValue) throws -> [ModelRequestBodyControl] {
        try array(value).map { value in
            guard case .dictionary(let fields) = value,
                  let kind = ModelRequestBodyControl.Kind(rawValue: try GuideToolArguments.string("kind", in: fields)),
                  case .bool(let enabled)? = fields["enabled"],
                  case .bool(let defaultActive)? = fields["default_active"],
                  case .bool(let sliderEnabled)? = fields["slider_enabled"],
                  case .bool(let rainbow)? = fields["rainbow_at_maximum"],
                  case .dictionary(let payload)? = fields["payload"] else { throw GuideError.invalidToolArguments }
            let options = try array(fields["options"]).map { value -> ModelRequestBodyControlOption in
                guard case .dictionary(let option) = value, case .dictionary(let payload)? = option["payload"] else {
                    throw GuideError.invalidToolArguments
                }
                return ModelRequestBodyControlOption(
                    id: try GuideToolArguments.string("id", in: option),
                    title: try GuideToolArguments.string("title", in: option), payload: payload
                )
            }
            let granularity: Double?
            if fields["slider_granularity"] == .null { granularity = nil }
            else { granularity = try decode(fields["slider_granularity"] ?? .null) }
            return ModelRequestBodyControl(
                id: try GuideToolArguments.string("id", in: fields), title: try GuideToolArguments.string("title", in: fields),
                kind: kind, isEnabled: enabled, defaultIsActive: defaultActive,
                defaultOptionID: try storedOptionalString("default_option_id", in: fields),
                isSliderEnabled: sliderEnabled,
                sliderGranularity: granularity,
                sliderStartColorHex: try storedOptionalString("slider_start_color", in: fields),
                sliderEndColorHex: try storedOptionalString("slider_end_color", in: fields),
                usesRainbowAtMaximum: rainbow, payload: payload, options: options
            )
        }
    }

    private static func decode<T: Decodable>(_ value: JSONValue) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private static func storedOptionalString(_ key: String, in fields: [String: JSONValue]) throws -> String? {
        if fields[key] == .null { return nil }
        return try GuideToolArguments.string(key, in: fields)
    }
}
