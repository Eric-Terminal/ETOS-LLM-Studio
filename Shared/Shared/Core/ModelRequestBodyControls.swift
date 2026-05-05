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
    public var payload: [String: JSONValue]
    public var options: [ModelRequestBodyControlOption]

    public init(
        id: String = UUID().uuidString,
        title: String,
        kind: Kind,
        isEnabled: Bool = true,
        defaultIsActive: Bool = false,
        defaultOptionID: String? = nil,
        payload: [String: JSONValue] = [:],
        options: [ModelRequestBodyControlOption] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isEnabled = isEnabled
        self.defaultIsActive = defaultIsActive
        self.defaultOptionID = defaultOptionID
        self.payload = payload
        self.options = options
    }
}

public struct ModelRequestBodyControlState: Codable, Hashable, Sendable {
    public var toggleValuesByControlID: [String: Bool]
    public var selectedOptionIDsByControlID: [String: String]

    public init(
        toggleValuesByControlID: [String: Bool] = [:],
        selectedOptionIDsByControlID: [String: String] = [:]
    ) {
        self.toggleValuesByControlID = toggleValuesByControlID
        self.selectedOptionIDsByControlID = selectedOptionIDsByControlID
    }

    public var isEmpty: Bool {
        toggleValuesByControlID.isEmpty && selectedOptionIDsByControlID.isEmpty
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

        return ModelRequestBodyControlState(
            toggleValuesByControlID: toggleValuesByControlID,
            selectedOptionIDsByControlID: selectedOptionIDsByControlID
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
            return ModelRequestBodyControl(
                title: NSLocalizedString("思考预算", comment: ""),
                kind: .optionGroup,
                defaultOptionID: "medium",
                options: [
                    ModelRequestBodyControlOption(id: "minimal", title: NSLocalizedString("minimal", comment: ""), payload: ["thinking_level": .string("MINIMAL")]),
                    ModelRequestBodyControlOption(id: "low", title: NSLocalizedString("low", comment: ""), payload: ["thinking_level": .string("LOW")]),
                    ModelRequestBodyControlOption(id: "medium", title: NSLocalizedString("medium", comment: ""), payload: ["thinking_level": .string("MEDIUM")]),
                    ModelRequestBodyControlOption(id: "high", title: NSLocalizedString("high", comment: ""), payload: ["thinking_level": .string("HIGH")]),
                    ModelRequestBodyControlOption(id: "auto", title: NSLocalizedString("自动", comment: ""), payload: ["thinkingBudget": .int(-1)]),
                    ModelRequestBodyControlOption(id: "off", title: NSLocalizedString("关闭", comment: ""), payload: ["thinkingBudget": .int(0)])
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

    private static func loadState(forKey key: String, userDefaults: UserDefaults) -> ModelRequestBodyControlState? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ModelRequestBodyControlState.self, from: data)
    }

    private static func saveState(
        _ state: ModelRequestBodyControlState,
        forKey key: String,
        userDefaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        userDefaults.set(data, forKey: key)
    }

    private static func signature(for controls: [ModelRequestBodyControl]) -> String {
        var components: [String] = []
        for control in controls.sorted(by: { $0.id < $1.id }) {
            components.append("control")
            components.append(control.id)
            components.append(control.kind.rawValue)
            components.append(control.isEnabled ? "1" : "0")
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
