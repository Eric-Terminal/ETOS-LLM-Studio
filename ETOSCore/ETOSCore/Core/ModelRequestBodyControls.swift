// ============================================================================
// ModelRequestBodyControls.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责模型请求体控制项、默认值、状态归一化与运行时持久化签名。
// ============================================================================

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct ModelRequestBodyControlOption: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var payload: [String: JSONValue]

    public init(
        id: String = UUID().uuidString,
        title: String,
        payload: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.title = title
        self.payload = payload
    }
}

public struct ModelRequestBodyControl: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case toggle
        case optionGroup
    }

    public var id: String
    public var title: String
    public var kind: Kind
    public var isEnabled: Bool
    public var defaultIsActive: Bool
    public var defaultOptionID: String?
    public var isSliderEnabled: Bool
    public var sliderGranularity: Double?
    public var sliderStartColorHex: String?
    public var sliderEndColorHex: String?
    public var usesRainbowAtMaximum: Bool
    public var payload: [String: JSONValue]
    public var options: [ModelRequestBodyControlOption]

    public init(
        id: String = UUID().uuidString,
        title: String,
        kind: Kind,
        isEnabled: Bool = true,
        defaultIsActive: Bool = false,
        defaultOptionID: String? = nil,
        isSliderEnabled: Bool = false,
        sliderGranularity: Double? = nil,
        sliderStartColorHex: String? = nil,
        sliderEndColorHex: String? = nil,
        usesRainbowAtMaximum: Bool = false,
        payload: [String: JSONValue] = [:],
        options: [ModelRequestBodyControlOption] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isEnabled = isEnabled
        self.defaultIsActive = defaultIsActive
        self.defaultOptionID = defaultOptionID
        self.isSliderEnabled = isSliderEnabled
        self.sliderGranularity = sliderGranularity
        self.sliderStartColorHex = sliderStartColorHex
        self.sliderEndColorHex = sliderEndColorHex
        self.usesRainbowAtMaximum = usesRainbowAtMaximum
        self.payload = payload
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case isEnabled
        case defaultIsActive
        case defaultOptionID
        case isSliderEnabled
        case sliderGranularity
        case sliderStartColorHex
        case sliderEndColorHex
        case usesRainbowAtMaximum
        case payload
        case options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(Kind.self, forKey: .kind)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        defaultIsActive = try container.decode(Bool.self, forKey: .defaultIsActive)
        defaultOptionID = try container.decodeIfPresent(String.self, forKey: .defaultOptionID)
        isSliderEnabled = try container.decodeIfPresent(Bool.self, forKey: .isSliderEnabled) ?? false
        sliderGranularity = try container.decodeIfPresent(Double.self, forKey: .sliderGranularity)
        sliderStartColorHex = try container.decodeIfPresent(String.self, forKey: .sliderStartColorHex)
        sliderEndColorHex = try container.decodeIfPresent(String.self, forKey: .sliderEndColorHex)
        usesRainbowAtMaximum = try container.decodeIfPresent(Bool.self, forKey: .usesRainbowAtMaximum) ?? false
        payload = try container.decode([String: JSONValue].self, forKey: .payload)
        options = try container.decode([ModelRequestBodyControlOption].self, forKey: .options)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(defaultIsActive, forKey: .defaultIsActive)
        try container.encodeIfPresent(defaultOptionID, forKey: .defaultOptionID)
        try container.encode(isSliderEnabled, forKey: .isSliderEnabled)
        try container.encodeIfPresent(sliderGranularity, forKey: .sliderGranularity)
        try container.encodeIfPresent(sliderStartColorHex, forKey: .sliderStartColorHex)
        try container.encodeIfPresent(sliderEndColorHex, forKey: .sliderEndColorHex)
        try container.encode(usesRainbowAtMaximum, forKey: .usesRainbowAtMaximum)
        try container.encode(payload, forKey: .payload)
        try container.encode(options, forKey: .options)
    }
}

public extension ModelRequestBodyControl {
    /// 从首个已填写选项推断同组空白选项应预填的参数键，不复制具体值。
    var suggestedOptionPayloadKeys: [String] {
        guard kind == .optionGroup else { return [] }
        for option in options where !option.payload.isEmpty {
            return option.payload.keys.sorted()
        }
        return []
    }

    /// 复制配置内容并重建控制与选项 ID，避免导入后与现有运行状态串联。
    func duplicatedWithNewIdentifiers() -> ModelRequestBodyControl {
        var optionIDMap: [String: String] = [:]
        let duplicatedOptions = options.map { option in
            let newID = UUID().uuidString
            optionIDMap[option.id] = newID
            return ModelRequestBodyControlOption(
                id: newID,
                title: option.title,
                payload: option.payload
            )
        }

        return ModelRequestBodyControl(
            id: UUID().uuidString,
            title: title,
            kind: kind,
            isEnabled: isEnabled,
            defaultIsActive: defaultIsActive,
            defaultOptionID: defaultOptionID.flatMap { optionIDMap[$0] },
            isSliderEnabled: isSliderEnabled,
            sliderGranularity: sliderGranularity,
            sliderStartColorHex: sliderStartColorHex,
            sliderEndColorHex: sliderEndColorHex,
            usesRainbowAtMaximum: usesRainbowAtMaximum,
            payload: payload,
            options: duplicatedOptions
        )
    }
}

public struct ModelRequestBodyControlState: Codable, Hashable, Sendable {
    public var toggleValuesByControlID: [String: Bool]
    public var selectedOptionIDsByControlID: [String: String]
    public var sliderPositionsByControlID: [String: Double]

    public init(
        toggleValuesByControlID: [String: Bool] = [:],
        selectedOptionIDsByControlID: [String: String] = [:],
        sliderPositionsByControlID: [String: Double] = [:]
    ) {
        self.toggleValuesByControlID = toggleValuesByControlID
        self.selectedOptionIDsByControlID = selectedOptionIDsByControlID
        self.sliderPositionsByControlID = sliderPositionsByControlID
    }

    public var isEmpty: Bool {
        toggleValuesByControlID.isEmpty
            && selectedOptionIDsByControlID.isEmpty
            && sliderPositionsByControlID.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case toggleValuesByControlID
        case selectedOptionIDsByControlID
        case sliderPositionsByControlID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toggleValuesByControlID = try container.decodeIfPresent(
            [String: Bool].self,
            forKey: .toggleValuesByControlID
        ) ?? [:]
        selectedOptionIDsByControlID = try container.decodeIfPresent(
            [String: String].self,
            forKey: .selectedOptionIDsByControlID
        ) ?? [:]
        sliderPositionsByControlID = try container.decodeIfPresent(
            [String: Double].self,
            forKey: .sliderPositionsByControlID
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toggleValuesByControlID, forKey: .toggleValuesByControlID)
        try container.encode(selectedOptionIDsByControlID, forKey: .selectedOptionIDsByControlID)
        try container.encode(sliderPositionsByControlID, forKey: .sliderPositionsByControlID)
    }
}

public enum ModelRequestBodyControlCompiler {
    public static func effectiveOverrideParameters(
        base: [String: JSONValue],
        controls: [ModelRequestBodyControl],
        state: ModelRequestBodyControlState
    ) -> [String: JSONValue] {
        var result = base
        for control in controls where control.isEnabled {
            switch control.kind {
            case .toggle:
                let isActive = state.toggleValuesByControlID[control.id] ?? control.defaultIsActive
                guard isActive else { continue }
                result = merged(result, control.payload)
            case .optionGroup:
                if control.isSliderEnabled,
                   let descriptor = ModelRequestBodyControlSliderDescriptor(control: control) {
                    result = merged(result, descriptor.payload(for: descriptor.position(in: state)))
                    continue
                }
                guard let selectedOptionID = state.selectedOptionIDsByControlID[control.id] ?? control.defaultOptionID,
                      let option = control.options.first(where: { $0.id == selectedOptionID }) else {
                    continue
                }
                result = merged(result, option.payload)
            }
        }
        return result
    }

    public static func defaultState(
        for controls: [ModelRequestBodyControl],
        inheriting inheritedState: ModelRequestBodyControlState? = nil
    ) -> ModelRequestBodyControlState {
        guard let inheritedState else {
            return ModelRequestBodyControlState()
        }
        return normalized(inheritedState, for: controls)
    }

    public static func normalized(
        _ state: ModelRequestBodyControlState,
        for controls: [ModelRequestBodyControl]
    ) -> ModelRequestBodyControlState {
        let validToggleIDs = Set(controls.filter { $0.kind == .toggle }.map(\.id))
        let validOptionIDsByControlID = Dictionary(uniqueKeysWithValues: controls.compactMap { control -> (String, Set<String>)? in
            guard control.kind == .optionGroup else { return nil }
            return (control.id, Set(control.options.map(\.id)))
        })

        let toggleValuesByControlID = state.toggleValuesByControlID.filter { validToggleIDs.contains($0.key) }
        let selectedOptionIDsByControlID = state.selectedOptionIDsByControlID.filter { controlID, optionID in
            guard let validOptionIDs = validOptionIDsByControlID[controlID] else { return false }
            return validOptionIDs.contains(optionID)
        }
        let validSliderIDs = Set(controls.filter {
            $0.kind == .optionGroup && $0.isSliderEnabled && $0.options.count >= 2
        }.map(\.id))
        let sliderPositionsByControlID = state.sliderPositionsByControlID.compactMapValues { position in
            position.isFinite ? min(max(position, 0), 1) : nil
        }.filter { validSliderIDs.contains($0.key) }

        return ModelRequestBodyControlState(
            toggleValuesByControlID: toggleValuesByControlID,
            selectedOptionIDsByControlID: selectedOptionIDsByControlID,
            sliderPositionsByControlID: sliderPositionsByControlID
        )
    }

    public static func merged(
        _ base: [String: JSONValue],
        _ overlay: [String: JSONValue]
    ) -> [String: JSONValue] {
        var result = base
        for (key, value) in overlay {
            if let existing = result[key] {
                result[key] = merge(existing, with: value)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func merge(_ base: JSONValue, with overlay: JSONValue) -> JSONValue {
        switch (base, overlay) {
        case (.dictionary(let baseDictionary), .dictionary(let overlayDictionary)):
            return .dictionary(merged(baseDictionary, overlayDictionary))
        default:
            return overlay
        }
    }
}

public enum ProviderAPIFormatFamily {
    case openAICompatible
    case openAIResponses
    case gemini
    case anthropic

    public init(apiFormat: String) {
        let normalized = apiFormat
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized == "openai-responses"
            || normalized == "openai-response"
            || normalized.contains("responses") {
            self = .openAIResponses
        } else if normalized.contains("anthropic") || normalized.contains("claude") {
            self = .anthropic
        } else if normalized.contains("gemini") || normalized.contains("google") || normalized.contains("vertex") {
            self = .gemini
        } else {
            self = .openAICompatible
        }
    }
}

public enum ModelRequestBodyControlDefaults {
    public static func temperatureControl() -> ModelRequestBodyControl {
        ModelRequestBodyControl(
            title: NSLocalizedString("温度", comment: ""),
            kind: .toggle,
            defaultIsActive: true,
            payload: ["temperature": .double(1)]
        )
    }

    public static func initialToggleControl(existingControls: [ModelRequestBodyControl]) -> ModelRequestBodyControl {
        if existingControls.contains(where: { $0.kind == .toggle }) {
            return ModelRequestBodyControl(title: "", kind: .toggle)
        }
        return temperatureControl()
    }

    public static func thinkingOptionGroup(for apiFormat: String) -> ModelRequestBodyControl {
        switch ProviderAPIFormatFamily(apiFormat: apiFormat) {
        case .anthropic:
            return ModelRequestBodyControl(
                title: NSLocalizedString("思考预算", comment: ""),
                kind: .optionGroup,
                defaultOptionID: "medium",
                options: [
                    ModelRequestBodyControlOption(id: "low", title: NSLocalizedString("low", comment: ""), payload: ["effort": .string("low")]),
                    ModelRequestBodyControlOption(id: "medium", title: NSLocalizedString("medium", comment: ""), payload: ["effort": .string("medium")]),
                    ModelRequestBodyControlOption(id: "high", title: NSLocalizedString("high", comment: ""), payload: ["effort": .string("high")]),
                    ModelRequestBodyControlOption(id: "budget-2048", title: "2048", payload: ["thinking": .dictionary(["type": .string("enabled"), "budget_tokens": .int(2048)])])
                ]
            )
        case .gemini:
            func thinkingConfigPayload(_ payload: [String: JSONValue]) -> [String: JSONValue] {
                [
                    "generationConfig": .dictionary([
                        "thinkingConfig": .dictionary(payload)
                    ])
                ]
            }
            return ModelRequestBodyControl(
                title: NSLocalizedString("思考预算", comment: ""),
                kind: .optionGroup,
                defaultOptionID: "medium",
                options: [
                    ModelRequestBodyControlOption(id: "minimal", title: NSLocalizedString("minimal", comment: ""), payload: thinkingConfigPayload(["thinkingLevel": .string("MINIMAL")])),
                    ModelRequestBodyControlOption(id: "low", title: NSLocalizedString("low", comment: ""), payload: thinkingConfigPayload(["thinkingLevel": .string("LOW")])),
                    ModelRequestBodyControlOption(id: "medium", title: NSLocalizedString("medium", comment: ""), payload: thinkingConfigPayload(["thinkingLevel": .string("MEDIUM")])),
                    ModelRequestBodyControlOption(id: "high", title: NSLocalizedString("high", comment: ""), payload: thinkingConfigPayload(["thinkingLevel": .string("HIGH")])),
                    ModelRequestBodyControlOption(id: "auto", title: NSLocalizedString("自动", comment: ""), payload: thinkingConfigPayload(["thinkingBudget": .int(-1)])),
                    ModelRequestBodyControlOption(id: "off", title: NSLocalizedString("关闭", comment: ""), payload: thinkingConfigPayload(["thinkingBudget": .int(0)]))
                ]
            )
        case .openAICompatible, .openAIResponses:
            return ModelRequestBodyControl(
                title: NSLocalizedString("思考预算", comment: ""),
                kind: .optionGroup,
                defaultOptionID: "medium",
                options: [
                    ModelRequestBodyControlOption(id: "none", title: NSLocalizedString("none", comment: ""), payload: ["reasoning_effort": .string("none")]),
                    ModelRequestBodyControlOption(id: "minimal", title: NSLocalizedString("minimal", comment: ""), payload: ["reasoning_effort": .string("minimal")]),
                    ModelRequestBodyControlOption(id: "low", title: NSLocalizedString("low", comment: ""), payload: ["reasoning_effort": .string("low")]),
                    ModelRequestBodyControlOption(id: "medium", title: NSLocalizedString("medium", comment: ""), payload: ["reasoning_effort": .string("medium")]),
                    ModelRequestBodyControlOption(id: "high", title: NSLocalizedString("high", comment: ""), payload: ["reasoning_effort": .string("high")]),
                    ModelRequestBodyControlOption(id: "xhigh", title: NSLocalizedString("xhigh", comment: ""), payload: ["reasoning_effort": .string("xhigh")])
                ]
            )
        }
    }

    public static func initialOptionGroupControl(
        existingControls: [ModelRequestBodyControl],
        apiFormat: String
    ) -> ModelRequestBodyControl {
        if existingControls.contains(where: { $0.kind == .optionGroup }) {
            return ModelRequestBodyControl(title: "", kind: .optionGroup)
        }
        return thinkingOptionGroup(for: apiFormat)
    }
}

public enum ModelRequestBodyControlRuntimeStore {
    private static let perModelPrefix = "requestBodyControls.state.model."
    private static let signaturePrefix = "requestBodyControls.state.signature."
    private static let inheritedStateKey = "requestBodyControls.state.inherited"

    public static func state(
        forModelKey modelKey: String,
        controls: [ModelRequestBodyControl],
        userDefaults: UserDefaults = .standard
    ) -> ModelRequestBodyControlState {
        if let stored = loadState(forKey: perModelPrefix + modelKey, userDefaults: userDefaults) {
            return ModelRequestBodyControlCompiler.normalized(stored, for: controls)
        }
        let signature = signature(for: controls)
        if let stored = loadState(forKey: signaturePrefix + signature, userDefaults: userDefaults) {
            return ModelRequestBodyControlCompiler.normalized(stored, for: controls)
        }
        let inherited = loadState(forKey: inheritedStateKey, userDefaults: userDefaults)
        return ModelRequestBodyControlCompiler.defaultState(for: controls, inheriting: inherited)
    }

    public static func save(
        _ state: ModelRequestBodyControlState,
        forModelKey modelKey: String,
        controls: [ModelRequestBodyControl],
        userDefaults: UserDefaults = .standard
    ) {
        let normalized = ModelRequestBodyControlCompiler.normalized(state, for: controls)
        saveState(normalized, forKey: perModelPrefix + modelKey, userDefaults: userDefaults)
        saveState(normalized, forKey: signaturePrefix + signature(for: controls), userDefaults: userDefaults)
        saveState(normalized, forKey: inheritedStateKey, userDefaults: userDefaults)
    }

    /// 仅更新单个开关，保留同一模型中其他控制项的运行态。
    public static func saveToggleValue(
        _ isActive: Bool,
        forControlID controlID: String,
        forModelKey modelKey: String,
        controls: [ModelRequestBodyControl],
        userDefaults: UserDefaults = .standard
    ) {
        var currentState = state(
            forModelKey: modelKey,
            controls: controls,
            userDefaults: userDefaults
        )
        currentState.toggleValuesByControlID[controlID] = isActive
        save(
            currentState,
            forModelKey: modelKey,
            controls: controls,
            userDefaults: userDefaults
        )
    }

    /// 更新滑块位置时同步最近档位，保证关闭滑块后仍能沿用当前选择。
    public static func saveSliderPosition(
        _ position: Double,
        for control: ModelRequestBodyControl,
        forModelKey modelKey: String,
        controls: [ModelRequestBodyControl],
        userDefaults: UserDefaults = .standard
    ) {
        guard let descriptor = ModelRequestBodyControlSliderDescriptor(control: control) else { return }
        var currentState = state(
            forModelKey: modelKey,
            controls: controls,
            userDefaults: userDefaults
        )
        let normalizedPosition = descriptor.normalized(position)
        currentState.sliderPositionsByControlID[control.id] = normalizedPosition
        currentState.selectedOptionIDsByControlID[control.id] = descriptor.nearestOptionID(
            at: normalizedPosition
        )
        save(
            currentState,
            forModelKey: modelKey,
            controls: controls,
            userDefaults: userDefaults
        )
    }

    private static func loadState(forKey key: String, userDefaults: UserDefaults) -> ModelRequestBodyControlState? {
        guard let data = dataValue(forKey: key, userDefaults: userDefaults) else { return nil }
        return try? JSONDecoder().decode(ModelRequestBodyControlState.self, from: data)
    }

    private static func saveState(
        _ state: ModelRequestBodyControlState,
        forKey key: String,
        userDefaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        saveData(data, forKey: key, userDefaults: userDefaults)
    }

    private static func usesDatabase(userDefaults: UserDefaults) -> Bool {
        userDefaults === UserDefaults.standard
    }

    private static func dataValue(forKey key: String, userDefaults: UserDefaults) -> Data? {
        guard usesDatabase(userDefaults: userDefaults) else {
            return userDefaults.data(forKey: key)
        }
        AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        if let stored = Persistence.readAppConfigText(key: key),
           let data = stored.data(using: .utf8) {
            return data
        }
        return nil
    }

    private static func saveData(_ data: Data, forKey key: String, userDefaults: UserDefaults) {
        guard usesDatabase(userDefaults: userDefaults) else {
            userDefaults.set(data, forKey: key)
            return
        }
        guard let encoded = String(data: data, encoding: .utf8) else { return }
        Persistence.writeAppConfig(key: key, text: encoded, typeHint: "text")
    }

    private static func signature(for controls: [ModelRequestBodyControl]) -> String {
        var components: [String] = []
        for control in controls.sorted(by: { $0.id < $1.id }) {
            components.append("control")
            components.append(control.id)
            components.append(control.kind.rawValue)
            components.append(control.isEnabled ? "1" : "0")
            components.append(control.isSliderEnabled ? "slider-1" : "slider-0")
            for (key, value) in control.payload.sorted(by: { $0.key < $1.key }) {
                components.append("payload")
                components.append(key)
                components.append(value.prettyPrintedCompact())
            }
            for option in control.options.sorted(by: { $0.id < $1.id }) {
                components.append("option")
                components.append(option.id)
                for (key, value) in option.payload.sorted(by: { $0.key < $1.key }) {
                    components.append("optionPayload")
                    components.append(key)
                    components.append(value.prettyPrintedCompact())
                }
            }
        }
        let source = components.joined(separator: "\u{1F}")
        guard let data = source.data(using: .utf8) else {
            return source
        }
#if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
#else
        return data.base64EncodedString()
#endif
    }
}
