// ============================================================================
// ModelSettingsView.swift
// ============================================================================
// ModelSettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct ModelSettingsView: View {
    @Binding var model: Model
    let provider: Provider
    let onSave: () -> Void
    @State private var expressionEntries: [ExpressionEntry] = []
    @State private var requestBodyMode: Model.RequestBodyOverrideMode = .expression
    @State private var rawJSONInput: String = "{}"
    @State private var rawJSONError: String?

    init(model: Binding<Model>, provider: Provider, onSave: @escaping () -> Void = {}) {
        _model = model
        self.provider = provider
        self.onSave = onSave
    }
    
    var body: some View {
        let preview = requestBodyPreview

        Form {
            Section(
                header: Text(NSLocalizedString("基础信息", comment: "")),
                footer: Text(NSLocalizedString("模型ID是 API 调用时使用的真实标识，模型名称是 App 内展示给用户的别名。", comment: ""))
            ) {
                TextField(NSLocalizedString("模型名称", comment: ""), text: $model.displayName)
                TextField(NSLocalizedString("模型ID", comment: ""), text: $model.modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .etFont(.footnote.monospaced())
            }

            Section(NSLocalizedString("模型能力", comment: "")) {
                Toggle(NSLocalizedString("聊天", comment: ""), isOn: capabilityBinding(.chat))
                Toggle(NSLocalizedString("工具", comment: ""), isOn: capabilityBinding(.toolCalling))
                Toggle(NSLocalizedString("语音转文字", comment: ""), isOn: capabilityBinding(.speechToText))
                Toggle(NSLocalizedString("文字转语音", comment: ""), isOn: capabilityBinding(.textToSpeech))
                Toggle(NSLocalizedString("嵌入", comment: ""), isOn: capabilityBinding(.embedding))
                Toggle(NSLocalizedString("生图", comment: ""), isOn: capabilityBinding(.imageGeneration))
            }

            Section(NSLocalizedString("请求体编辑方式", comment: "")) {
                Picker(NSLocalizedString("编辑方式", comment: ""), selection: $requestBodyMode) {
                    Text(NSLocalizedString("参数表达式", comment: "")).tag(Model.RequestBodyOverrideMode.expression)
                    Text(NSLocalizedString("原始 JSON", comment: "")).tag(Model.RequestBodyOverrideMode.rawJSON)
                }
                .pickerStyle(.segmented)
                .tint(.blue)
            }

            if requestBodyMode == .expression {
                Section(NSLocalizedString("参数表达式", comment: "")) {
                    ForEach($expressionEntries) { $entry in
                        ExpressionRow(entry: $entry)
                            .onChange(of: entry.text) { _, _ in
                                validateEntry(withId: entry.id)
                            }
                    }
                    .onDelete(perform: deleteEntries)
                    
                    Button {
                        addEmptyEntry()
                    } label: {
                        Label(NSLocalizedString("添加表达式", comment: ""), systemImage: "plus")
                    }
                }
                
                Section(NSLocalizedString("表达式说明", comment: "")) {
                    Label(NSLocalizedString("用 = 指定参数，比如: thinking_budget = 128", comment: ""), systemImage: "character.cursor.ibeam")
                    Label(NSLocalizedString("嵌套结构使用 {}，例如: chat_template_kwargs = {thinking = false}", comment: ""), systemImage: "curlybraces")
                    Label(NSLocalizedString("重复 key 会自动合并字典，方便拆分输入", comment: ""), systemImage: "square.stack.3d.up")
                }
            } else {
                Section(
                    header: Text(NSLocalizedString("原始 JSON", comment: "")),
                    footer: Text(NSLocalizedString("填写 JSON 对象并与默认请求体合并。示例：{\"extra_body\": {\"abc\": \"123\"}}", comment: ""))
                ) {
                    TextEditor(text: $rawJSONInput)
                        .etFont(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 180)
                        .onChange(of: rawJSONInput) { _, newValue in
                            validateRawJSON(newValue)
                        }

                    if let rawJSONError {
                        Text(rawJSONError)
                            .etFont(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section(NSLocalizedString("请求体预览", comment: "")) {
                Text(preview.text)
                    .etFont(.footnote.monospaced())
                    .foregroundStyle(preview.isPlaceholder ? .secondary : .primary)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(NSLocalizedString("模型信息", comment: ""))
        .onAppear(perform: loadEditorState)
        .onDisappear(perform: saveEditorState)
    }
}

// MARK: - 内部状态

extension ModelSettingsView {
    struct ExpressionEntry: Identifiable, Equatable {
        let id: UUID
        var text: String
        var error: String?
        
        init(id: UUID = UUID(), text: String, error: String? = nil) {
            self.id = id
            self.text = text
            self.error = error
        }
    }
    
    private func loadEditorState() {
        requestBodyMode = model.requestBodyOverrideMode
        loadExpressionEntriesFromModel()
        if let savedRawJSON = model.rawRequestBodyJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
           !savedRawJSON.isEmpty {
            rawJSONInput = savedRawJSON
        } else {
            rawJSONInput = ParameterExpressionParser.serializeRawJSONObject(parameters: model.overrideParameters)
        }
        validateRawJSON(rawJSONInput)
    }

    private func loadExpressionEntriesFromModel() {
        let serialized = ParameterExpressionParser.serialize(parameters: model.overrideParameters)
        if serialized.isEmpty {
            expressionEntries = [ExpressionEntry(text: "")]
        } else {
            expressionEntries = serialized.map { ExpressionEntry(text: $0) }
        }
    }
    
    private func addEmptyEntry() {
        expressionEntries.append(ExpressionEntry(text: ""))
    }
    
    private func deleteEntries(at offsets: IndexSet) {
        expressionEntries.remove(atOffsets: offsets)
        if expressionEntries.isEmpty {
            addEmptyEntry()
        }
    }
    
    private func validateEntry(withId id: UUID) {
        guard let index = expressionEntries.firstIndex(where: { $0.id == id }) else { return }
        var entry = expressionEntries[index]
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            entry.error = nil
            expressionEntries[index] = entry
            return
        }
        
        do {
            _ = try ParameterExpressionParser.parse(trimmed)
            entry.error = nil
        } catch {
            entry.error = error.localizedDescription
        }
        expressionEntries[index] = entry
    }
    
    private func saveEditorState() {
        model.requestBodyOverrideMode = requestBodyMode
        model.rawRequestBodyJSON = rawJSONInput

        switch requestBodyMode {
        case .expression:
            let result = parseExpressionEntries(entries: expressionEntries, shouldAnnotateErrors: true)
            expressionEntries = result.entries
            rawJSONError = nil
            if !result.hasError {
                model.overrideParameters = result.parameters
            }
        case .rawJSON:
            do {
                model.overrideParameters = try parseRawJSONInput(rawJSONInput)
                rawJSONError = nil
            } catch {
                rawJSONError = error.localizedDescription
            }
        @unknown default:
            let result = parseExpressionEntries(entries: expressionEntries, shouldAnnotateErrors: true)
            expressionEntries = result.entries
            rawJSONError = nil
            if !result.hasError {
                model.overrideParameters = result.parameters
            }
        }

        onSave()
    }

    private var requestBodyPreview: RequestBodyPreview {
        let result = previewOverrideParameters()
        if result.hasError {
            return RequestBodyPreview(
                text: requestBodyMode == .expression
                    ? NSLocalizedString("表达式有误，无法预览", comment: "")
                    : NSLocalizedString("JSON 有误，无法预览", comment: ""),
                isPlaceholder: true
            )
        }

        let payload = buildRequestPreviewPayload(
            apiFormat: provider.apiFormat,
            model: model,
            overrides: result.parameters
        )
        let sanitized = sanitizePreviewPayload(payload)
        return RequestBodyPreview(
            text: prettyPrintedJSON(sanitized),
            isPlaceholder: false
        )
    }

    private func previewOverrideParameters() -> (parameters: [String: JSONValue], hasError: Bool) {
        switch requestBodyMode {
        case .expression:
            let result = parseExpressionEntries(entries: expressionEntries, shouldAnnotateErrors: false)
            return (parameters: result.parameters, hasError: result.hasError)
        case .rawJSON:
            do {
                let parsed = try parseRawJSONInput(rawJSONInput)
                return (parameters: parsed, hasError: false)
            } catch {
                return (parameters: [:], hasError: true)
            }
        @unknown default:
            let result = parseExpressionEntries(entries: expressionEntries, shouldAnnotateErrors: false)
            return (parameters: result.parameters, hasError: result.hasError)
        }
    }

    private func parseExpressionEntries(
        entries: [ExpressionEntry],
        shouldAnnotateErrors: Bool
    ) -> (parameters: [String: JSONValue], hasError: Bool, entries: [ExpressionEntry]) {
        var updatedEntries = entries
        var parsedExpressions: [ParameterExpressionParser.ParsedExpression] = []
        var hasError = false

        for index in updatedEntries.indices {
            let trimmed = updatedEntries[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                if shouldAnnotateErrors {
                    updatedEntries[index].error = nil
                }
                continue
            }

            do {
                let parsed = try ParameterExpressionParser.parse(trimmed)
                parsedExpressions.append(parsed)
                if shouldAnnotateErrors {
                    updatedEntries[index].error = nil
                }
            } catch {
                hasError = true
                if shouldAnnotateErrors {
                    updatedEntries[index].error = error.localizedDescription
                }
            }
        }

        let parameters = ParameterExpressionParser.buildParameters(from: parsedExpressions)
        return (parameters: parameters, hasError: hasError, entries: updatedEntries)
    }

    private func parseRawJSONInput(_ rawJSON: String) throws -> [String: JSONValue] {
        try ParameterExpressionParser.parseRawJSONObject(rawJSON)
    }

    private func validateRawJSON(_ rawJSON: String) {
        guard requestBodyMode == .rawJSON else {
            rawJSONError = nil
            return
        }
        do {
            _ = try parseRawJSONInput(rawJSON)
            rawJSONError = nil
        } catch {
            rawJSONError = error.localizedDescription
        }
    }

    private func buildRequestPreviewPayload(
        apiFormat: String,
        model: Model,
        overrides: [String: JSONValue]
    ) -> [String: Any] {
        let overridesAny = overrides.mapValues { $0.toAny() }

        switch apiFormat {
        case "gemini":
            var payload: [String: Any] = [:]
            payload["contents"] = [
                [
                    "role": "user",
                    "parts": [
                        ["text": "<message>"]
                    ]
                ]
            ]

            var generationConfig: [String: Any] = [:]
            if let temperature = overridesAny["temperature"] { generationConfig["temperature"] = temperature }
            if let topP = overridesAny["top_p"] { generationConfig["topP"] = topP }
            if let topK = overridesAny["top_k"] { generationConfig["topK"] = topK }
            if let maxTokens = overridesAny["max_tokens"] { generationConfig["maxOutputTokens"] = maxTokens }
            if let thinkingBudget = overridesAny["thinking_budget"] {
                generationConfig["thinkingConfig"] = ["thinkingBudget": thinkingBudget]
            }
            if !generationConfig.isEmpty {
                payload["generationConfig"] = generationConfig
            }
            return payload

        case "anthropic":
            var payload: [String: Any] = [:]
            payload["model"] = model.modelName
            payload["messages"] = [
                [
                    "role": "user",
                    "content": "<message>"
                ]
            ]

            payload["max_tokens"] = overridesAny["max_tokens"] ?? 8192
            if let temperature = overridesAny["temperature"] { payload["temperature"] = temperature }
            if let topP = overridesAny["top_p"] { payload["top_p"] = topP }
            if let topK = overridesAny["top_k"] { payload["top_k"] = topK }
            if let stream = overridesAny["stream"] { payload["stream"] = stream }
            if let thinkingBudget = overridesAny["thinking_budget"] {
                payload["thinking"] = [
                    "type": "enabled",
                    "budget_tokens": thinkingBudget
                ]
            }
            return payload

        default:
            if resolvedOpenAIPreviewMode(from: overridesAny) == .responses {
                var payload = sanitizedResponsesPreviewOverrides(overridesAny)
                payload["model"] = model.modelName
                payload["input"] = [
                    [
                        "type": "message",
                        "role": "user",
                        "content": [
                            [
                                "type": "input_text",
                                "text": "<message>"
                            ]
                        ]
                    ]
                ]
                return payload
            } else {
                var payload = sanitizedChatCompletionsPreviewOverrides(overridesAny)
                payload["model"] = model.modelName
                payload["messages"] = [
                    [
                        "role": "user",
                        "content": "<message>"
                    ]
                ]

                if let stream = payload["stream"] as? Bool, stream {
                    var streamOptions = payload["stream_options"] as? [String: Any] ?? [:]
                    if streamOptions["include_usage"] == nil {
                        streamOptions["include_usage"] = true
                    }
                    payload["stream_options"] = streamOptions
                }
                return payload
            }
        }
    }

    private enum OpenAIPreviewMode {
        case chatCompletions
        case responses
    }

    private var openAIResponsesSignalKeys: Set<String> {
        [
            "background",
            "context_management",
            "conversation",
            "include",
            "max_output_tokens",
            "previous_response_id",
            "reasoning",
            "store",
            "text",
            "truncation"
        ]
    }

    private var openAIControlOverrideKeys: Set<String> {
        [
            "openai_api",
            "openai_api_mode",
            "use_responses_api"
        ]
    }

    private var openAIChatCompletionsOnlyKeys: Set<String> {
        [
            "functions",
            "function_call",
            "messages",
            "stream_options"
        ]
    }

    private func normalizedOpenAIAPIValue(_ rawValue: String) -> OpenAIPreviewMode? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "responses", "response":
            return .responses
        case "chat", "chat_completion", "chat_completions":
            return .chatCompletions
        default:
            return nil
        }
    }

    private func boolValue(from rawValue: Any?) -> Bool? {
        switch rawValue {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "true", "1", "yes", "on":
                return true
            case "false", "0", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private func resolvedOpenAIPreviewMode(from overrides: [String: Any]) -> OpenAIPreviewMode {
        if let rawValue = overrides["openai_api"] as? String,
           let mode = normalizedOpenAIAPIValue(rawValue) {
            return mode
        }
        if let rawValue = overrides["openai_api_mode"] as? String,
           let mode = normalizedOpenAIAPIValue(rawValue) {
            return mode
        }
        if let useResponses = boolValue(from: overrides["use_responses_api"]) {
            return useResponses ? .responses : .chatCompletions
        }
        if overrides.keys.contains(where: { openAIResponsesSignalKeys.contains($0) }) {
            return .responses
        }
        return .chatCompletions
    }

    private func sanitizedChatCompletionsPreviewOverrides(_ overrides: [String: Any]) -> [String: Any] {
        overrides.filter {
            !openAIControlOverrideKeys.contains($0.key) && !openAIResponsesSignalKeys.contains($0.key)
        }
    }

    private func sanitizedResponsesPreviewOverrides(_ overrides: [String: Any]) -> [String: Any] {
        var sanitized = overrides.filter {
            !openAIControlOverrideKeys.contains($0.key) && !openAIChatCompletionsOnlyKeys.contains($0.key)
        }
        if sanitized["max_output_tokens"] == nil, let legacyMaxTokens = sanitized["max_tokens"] {
            sanitized["max_output_tokens"] = legacyMaxTokens
        }
        sanitized.removeValue(forKey: "max_tokens")
        sanitized.removeValue(forKey: "input")
        return sanitized
    }

    private func sanitizePreviewPayload(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, item) in dict {
                if key == "data" {
                    result[key] = "[data omitted]"
                } else if key == "url", let url = item as? String, url.hasPrefix("data:") {
                    result[key] = "[base64 image omitted]"
                } else {
                    result[key] = sanitizePreviewPayload(item)
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { sanitizePreviewPayload($0) }
        }
        return value
    }

    private func prettyPrintedJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "\(value)"
        }
        return string
    }

    private func capabilityBinding(_ capability: Model.Capability) -> Binding<Bool> {
        Binding(
            get: {
                model.capabilities.contains(capability)
            },
            set: { isEnabled in
                var capabilitySet = Set(model.capabilities)
                if isEnabled {
                    capabilitySet.insert(capability)
                } else {
                    capabilitySet.remove(capability)
                }
                if capabilitySet.isEmpty {
                    capabilitySet.insert(.chat)
                }
                let ordered: [Model.Capability] = [.chat, .toolCalling, .speechToText, .textToSpeech, .embedding, .imageGeneration]
                model.capabilities = ordered.filter { capabilitySet.contains($0) }
            }
        )
    }
}

// MARK: - 子视图

private struct RequestBodyPreview {
    let text: String
    let isPlaceholder: Bool
}

private struct ExpressionRow: View {
    @Binding var entry: ModelSettingsView.ExpressionEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(NSLocalizedString("参数表达式，比如 temperature = 0.8", comment: ""), text: $entry.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .etFont(.body.monospaced())
            
            if let error = entry.error {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
