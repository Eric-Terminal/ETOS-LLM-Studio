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
    @State private var keyValueEntries: [KeyValueEntry] = []
    @State private var expressionEntries: [ExpressionEntry] = []
    @State private var requestBodyMode: Model.RequestBodyOverrideMode = .keyValue
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

            Section(
                header: Text(NSLocalizedString("用途", comment: "模型用途区块标题")),
                footer: Text(kindFooterText)
            ) {
                Picker(NSLocalizedString("用途", comment: "模型用途选择器标题"), selection: kindBinding) {
                    ForEach(ModelKind.allCases, id: \.self) { kind in
                        Text(kind.localizedName).tag(kind)
                    }
                }
            }

            Section(
                header: Text(NSLocalizedString("模型能力", comment: "模型能力区块标题")),
                footer: Text(capabilityFooterText)
            ) {
                modelCapabilityRows
            }

            Section(NSLocalizedString("自定义Body", comment: "")) {
                Picker(NSLocalizedString("编辑方式", comment: ""), selection: $requestBodyMode) {
                    Text(NSLocalizedString("键值对", comment: "")).tag(Model.RequestBodyOverrideMode.keyValue)
                    Text(NSLocalizedString("参数表达式", comment: "")).tag(Model.RequestBodyOverrideMode.expression)
                    Text(NSLocalizedString("原始 JSON", comment: "")).tag(Model.RequestBodyOverrideMode.rawJSON)
                }
            }

            structuredControlsSection

            if requestBodyMode == .keyValue {
                Section(NSLocalizedString("键值对", comment: "")) {
                    ForEach($keyValueEntries) { $entry in
                        KeyValueRow(entry: $entry)
                            .onChange(of: entry.key) { _, _ in
                                validateKeyValueEntry(withId: entry.id)
                            }
                            .onChange(of: entry.value) { _, _ in
                                validateKeyValueEntry(withId: entry.id)
                            }
                    }
                    .onDelete(perform: deleteKeyValueEntries)

                    Button {
                        addKeyValueEntry()
                    } label: {
                        Label(NSLocalizedString("添加键值对", comment: ""), systemImage: "plus")
                    }
                }
            } else if requestBodyMode == .expression {
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
                RequestBodyPreviewInlineView(preview: preview)
            }
        }
        .navigationTitle(NSLocalizedString("模型信息", comment: ""))
        .onAppear(perform: loadEditorState)
        .onDisappear(perform: saveEditorState)
    }
}

// MARK: - 内部状态

extension ModelSettingsView {
    struct KeyValueEntry: Identifiable, Equatable {
        let id: UUID
        var key: String
        var value: String
        var error: String?

        init(id: UUID = UUID(), key: String, value: String, error: String? = nil) {
            self.id = id
            self.key = key
            self.value = value
            self.error = error
        }
    }

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
        loadKeyValueEntriesFromModel()
        loadExpressionEntriesFromModel()
        if let savedRawJSON = model.rawRequestBodyJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
           !savedRawJSON.isEmpty {
            rawJSONInput = savedRawJSON
        } else {
            rawJSONInput = ParameterExpressionParser.serializeRawJSONObject(parameters: model.overrideParameters)
        }
        validateRawJSON(rawJSONInput)
    }

    private func loadKeyValueEntriesFromModel() {
        let entries = model.overrideParameters
            .sorted(by: { $0.key < $1.key })
            .map { KeyValueEntry(key: $0.key, value: keyValueString(for: $0.value)) }
        keyValueEntries = entries.isEmpty ? [KeyValueEntry(key: "", value: "")] : entries
    }

    private func loadExpressionEntriesFromModel() {
        let serialized = ParameterExpressionParser.serialize(parameters: model.overrideParameters)
        if serialized.isEmpty {
            expressionEntries = [ExpressionEntry(text: "")]
        } else {
            expressionEntries = serialized.map { ExpressionEntry(text: $0) }
        }
    }

    private func addKeyValueEntry() {
        keyValueEntries.append(KeyValueEntry(key: "", value: ""))
    }

    private func deleteKeyValueEntries(at offsets: IndexSet) {
        keyValueEntries.remove(atOffsets: offsets)
        if keyValueEntries.isEmpty {
            addKeyValueEntry()
        }
    }

    private func validateKeyValueEntry(withId id: UUID) {
        guard let index = keyValueEntries.firstIndex(where: { $0.id == id }) else { return }
        var entry = keyValueEntries[index]
        do {
            _ = try parseKeyValueEntry(entry)
            entry.error = nil
        } catch {
            entry.error = error.localizedDescription
        }
        keyValueEntries[index] = entry
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
        case .keyValue:
            let result = parseKeyValueEntries(entries: keyValueEntries, shouldAnnotateErrors: true)
            keyValueEntries = result.entries
            rawJSONError = nil
            if !result.hasError {
                model.overrideParameters = result.parameters
            }
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
            let result = parseKeyValueEntries(entries: keyValueEntries, shouldAnnotateErrors: true)
            keyValueEntries = result.entries
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
            let text = switch requestBodyMode {
            case .keyValue:
                NSLocalizedString("键值对有误，无法预览", comment: "")
            case .expression:
                NSLocalizedString("表达式有误，无法预览", comment: "")
            case .rawJSON:
                NSLocalizedString("JSON 有误，无法预览", comment: "")
            @unknown default:
                NSLocalizedString("自定义Body有误，无法预览", comment: "")
            }
            return RequestBodyPreview(
                text: text,
                isPlaceholder: true
            )
        }

        let effectiveOverrides = ModelRequestBodyControlCompiler.effectiveOverrideParameters(
            base: result.parameters,
            controls: model.requestBodyControls,
            state: model.defaultRequestBodyControlState
        )
        let payload = buildRequestPreviewPayload(
            apiFormat: provider.apiFormat,
            model: model,
            overrides: effectiveOverrides
        )
        let sanitized = sanitizePreviewPayload(payload)
        return RequestBodyPreview(
            text: prettyPrintedJSON(sanitized),
            isPlaceholder: false
        )
    }

    private func previewOverrideParameters() -> (parameters: [String: JSONValue], hasError: Bool) {
        switch requestBodyMode {
        case .keyValue:
            let result = parseKeyValueEntries(entries: keyValueEntries, shouldAnnotateErrors: false)
            return (parameters: result.parameters, hasError: result.hasError)
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

    private func parseKeyValueEntries(
        entries: [KeyValueEntry],
        shouldAnnotateErrors: Bool
    ) -> (parameters: [String: JSONValue], hasError: Bool, entries: [KeyValueEntry]) {
        var updatedEntries = entries
        var parsedExpressions: [ParameterExpressionParser.ParsedExpression] = []
        var hasError = false

        for index in updatedEntries.indices {
            do {
                if let parsed = try parseKeyValueEntry(updatedEntries[index]) {
                    parsedExpressions.append(parsed)
                }
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

        return (
            parameters: ParameterExpressionParser.buildParameters(from: parsedExpressions),
            hasError: hasError,
            entries: updatedEntries
        )
    }

    private func parseKeyValueEntry(_ entry: KeyValueEntry) throws -> ParameterExpressionParser.ParsedExpression? {
        let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty && value.isEmpty {
            return nil
        }
        guard !key.isEmpty else {
            throw ParameterExpressionParser.ParserError.invalidKey
        }
        if value.isEmpty {
            return ParameterExpressionParser.ParsedExpression(key: key, value: .string(""))
        }
        return try ParameterExpressionParser.parse("\(key) = \(entry.value)")
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

    private func keyValueString(for value: JSONValue) -> String {
        switch value {
        case .string(let string):
            return string
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .dictionary, .array, .null:
            return value.prettyPrintedCompact()
        }
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

    @ViewBuilder
    private var structuredControlsSection: some View {
        Section(
            header: Text(NSLocalizedString("结构化控制", comment: "")),
            footer: Text(NSLocalizedString("这些控制会在发送时覆盖上面的自定义Body，适合思考预算、搜索、温度等常切参数。", comment: ""))
        ) {
            if model.requestBodyControls.isEmpty {
                Text(NSLocalizedString("暂无结构化控制。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach($model.requestBodyControls) { $control in
                    RequestBodyControlEditor(
                        control: $control,
                        payloadDisplayMode: requestBodyMode
                    )
                }
                .onDelete(perform: deleteRequestBodyControls)
            }

            Menu {
                Button {
                    addToggleControl()
                } label: {
                    Label(NSLocalizedString("添加开关", comment: ""), systemImage: "power")
                }
                Button {
                    addOptionGroupControl()
                } label: {
                    Label(NSLocalizedString("添加组选项", comment: ""), systemImage: "list.bullet")
                }
            } label: {
                Label(NSLocalizedString("添加控制", comment: ""), systemImage: "plus")
            }
        }
    }

    private func addToggleControl() {
        model.requestBodyControls.append(
            ModelRequestBodyControl(
                title: NSLocalizedString("开启思考", comment: ""),
                kind: .toggle,
                payload: ["enable_thinking": .bool(true)]
            )
        )
    }

    private func addOptionGroupControl() {
        let lowID = "low"
        model.requestBodyControls.append(
            ModelRequestBodyControl(
                title: NSLocalizedString("思考预算", comment: ""),
                kind: .optionGroup,
                defaultOptionID: lowID,
                options: [
                    ModelRequestBodyControlOption(id: "minimal", title: NSLocalizedString("minimal", comment: ""), payload: ["thinking_budget": .string("minimal")]),
                    ModelRequestBodyControlOption(id: lowID, title: NSLocalizedString("low", comment: ""), payload: ["thinking_budget": .string("low")]),
                    ModelRequestBodyControlOption(id: "medium", title: NSLocalizedString("medium", comment: ""), payload: ["thinking_budget": .string("medium")]),
                    ModelRequestBodyControlOption(id: "high", title: NSLocalizedString("high", comment: ""), payload: ["thinking_budget": .string("high")]),
                    ModelRequestBodyControlOption(id: "xhigh", title: NSLocalizedString("xhigh", comment: ""), payload: ["thinking_budget": .string("xhigh")])
                ]
            )
        )
    }

    private func deleteRequestBodyControls(at offsets: IndexSet) {
        model.requestBodyControls.remove(atOffsets: offsets)
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

    private var kindBinding: Binding<ModelKind> {
        Binding(
            get: { model.kind },
            set: { newKind in
                guard model.kind != newKind else { return }
                model.resetCapabilityShape(for: newKind)
            }
        )
    }

    private var kindFooterText: String {
        switch model.kind {
        case .chat:
            return NSLocalizedString("用于普通对话。下面只需要开启这个模型实际支持的增强能力。", comment: "聊天模型用途说明")
        case .image:
            return NSLocalizedString("用于图片生成，会出现在生图模型列表中。", comment: "图片生成模型用途说明")
        case .embedding:
            return NSLocalizedString("用于长期记忆和检索向量化，不会出现在聊天模型列表中。", comment: "嵌入模型用途说明")
        case .rerank:
            return NSLocalizedString("用于检索结果重排，通常配合知识库或搜索结果精排使用。", comment: "重排模型用途说明")
        case .speechToText:
            return NSLocalizedString("用于把录音转换为文字。", comment: "语音转文字模型用途说明")
        case .textToSpeech:
            return NSLocalizedString("用于把文字转换为语音。", comment: "文字转语音模型用途说明")
        }
    }

    private var capabilityFooterText: String {
        switch model.kind {
        case .chat:
            if model.outputModalities.contains(.image) {
                return NSLocalizedString("开启“可生成图片”后，选中该模型的主聊天会直接按生图请求处理。", comment: "聊天模型生图能力说明")
            }
            return NSLocalizedString("这些开关描述模型能做什么；服务商原生工具等请求参数由适配器处理。", comment: "聊天模型能力说明")
        case .image:
            return NSLocalizedString("图片生成由用途决定；如果模型支持图生图，可以开启参考图片。", comment: "图片模型能力说明")
        case .embedding, .rerank, .speechToText, .textToSpeech:
            return NSLocalizedString("专用模型的输入和输出由用途决定，通常不需要额外配置。", comment: "专用模型能力说明")
        }
    }

    @ViewBuilder
    private var modelCapabilityRows: some View {
        switch model.kind {
        case .chat:
            Toggle(NSLocalizedString("可处理图片", comment: "聊天模型能力：图片输入"), isOn: modalityBinding(.image, keyPath: \.inputModalities))
            Toggle(NSLocalizedString("可处理音频", comment: "聊天模型能力：音频输入"), isOn: modalityBinding(.audio, keyPath: \.inputModalities))
            Toggle(NSLocalizedString("可处理文件", comment: "聊天模型能力：文件输入"), isOn: modalityBinding(.file, keyPath: \.inputModalities))
            Toggle(NSLocalizedString("可生成图片", comment: "聊天模型能力：图片输出"), isOn: modalityBinding(.image, keyPath: \.outputModalities))
            Toggle(NSLocalizedString("可调用工具", comment: "聊天模型能力：工具调用"), isOn: capabilityBinding(.toolCalling))
        case .image:
            Toggle(NSLocalizedString("支持参考图片", comment: "图片生成模型能力：参考图片输入"), isOn: modalityBinding(.image, keyPath: \.inputModalities))
        case .embedding:
            Text(NSLocalizedString("此模型用于生成文本向量。", comment: "嵌入模型能力说明"))
                .foregroundStyle(.secondary)
        case .rerank:
            Text(NSLocalizedString("此模型用于重新排序候选内容。", comment: "重排模型能力说明"))
                .foregroundStyle(.secondary)
        case .speechToText:
            Text(NSLocalizedString("此模型接收音频并输出文字。", comment: "语音转文字模型能力说明"))
                .foregroundStyle(.secondary)
        case .textToSpeech:
            Text(NSLocalizedString("此模型接收文字并输出语音。", comment: "文字转语音模型能力说明"))
                .foregroundStyle(.secondary)
        }
    }

    private func modalityBinding(
        _ modality: ModelModality,
        keyPath: WritableKeyPath<Model, [ModelModality]>
    ) -> Binding<Bool> {
        Binding(
            get: {
                model[keyPath: keyPath].contains(modality)
            },
            set: { isEnabled in
                var modalities = model[keyPath: keyPath]
                if isEnabled {
                    modalities.append(modality)
                } else {
                    modalities.removeAll { $0 == modality }
                }
                if keyPath == \Model.outputModalities {
                    model[keyPath: keyPath] = Model.orderedOutputModalities(modalities)
                } else {
                    model[keyPath: keyPath] = Model.orderedModalities(modalities)
                }
            }
        )
    }

    private func capabilityBinding(_ capability: ModelCapability) -> Binding<Bool> {
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
                model.capabilities = Model.orderedCapabilities(Array(capabilitySet))
            }
        )
    }

}

// MARK: - 子视图

private struct RequestBodyPreview {
    let text: String
    let isPlaceholder: Bool
}

private struct RequestBodyPreviewInlineView: View {
    let preview: RequestBodyPreview

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(preview.text)
                .etFont(.footnote.monospaced())
                .foregroundStyle(preview.isPlaceholder ? .secondary : .primary)
                .lineLimit(nil)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
                .padding(.vertical, 2)
        }
    }
}

private struct RequestBodyControlEditor: View {
    @Binding var control: ModelRequestBodyControl
    let payloadDisplayMode: Model.RequestBodyOverrideMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(NSLocalizedString("显示名称", comment: ""), text: $control.title)
                Picker(NSLocalizedString("类型", comment: ""), selection: $control.kind) {
                    Text(NSLocalizedString("开关", comment: "")).tag(ModelRequestBodyControl.Kind.toggle)
                    Text(NSLocalizedString("组选", comment: "")).tag(ModelRequestBodyControl.Kind.optionGroup)
                }
                .pickerStyle(.menu)
            }

            Toggle(NSLocalizedString("启用", comment: ""), isOn: $control.isEnabled)

            switch control.kind {
            case .toggle:
                Toggle(NSLocalizedString("默认开启", comment: ""), isOn: $control.defaultIsActive)
                RequestBodyPayloadEditor(
                    payloadDisplayMode: payloadDisplayMode,
                    payload: $control.payload
                )
            case .optionGroup:
                if control.options.isEmpty {
                    Text(NSLocalizedString("暂无选项。", comment: ""))
                        .foregroundStyle(.secondary)
                } else {
                    let lastIndex = control.options.indices.last
                    ForEach(control.options.indices, id: \.self) { index in
                        let optionID = control.options[index].id
                        RequestBodyOptionEditor(
                            option: $control.options[index],
                            defaultOptionID: $control.defaultOptionID,
                            payloadDisplayMode: payloadDisplayMode,
                            onDelete: {
                                deleteOption(withID: optionID)
                            }
                        )
                        if let lastIndex, index < lastIndex {
                            Divider()
                                .padding(.vertical, 8)
                        }
                    }
                }

                Button {
                    addOption()
                } label: {
                    Label(NSLocalizedString("添加选项", comment: ""), systemImage: "plus")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func addOption() {
        let optionID = UUID().uuidString
        control.options.append(
            ModelRequestBodyControlOption(
                id: optionID,
                title: NSLocalizedString("新选项", comment: ""),
                payload: [:]
            )
        )
        if control.defaultOptionID == nil {
            control.defaultOptionID = optionID
        }
    }

    private func deleteOptions(at offsets: IndexSet) {
        let deletedIDs = offsets.compactMap { index in
            control.options.indices.contains(index) ? control.options[index].id : nil
        }
        control.options.remove(atOffsets: offsets)
        if let defaultOptionID = control.defaultOptionID,
           deletedIDs.contains(defaultOptionID) {
            control.defaultOptionID = control.options.first?.id
        }
    }

    private func deleteOption(withID optionID: String) {
        guard let index = control.options.firstIndex(where: { $0.id == optionID }) else { return }
        deleteOptions(at: IndexSet(integer: index))
    }
}

private struct RequestBodyOptionEditor: View {
    @Binding var option: ModelRequestBodyControlOption
    @Binding var defaultOptionID: String?
    let payloadDisplayMode: Model.RequestBodyOverrideMode
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("选项名称", comment: ""))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                    TextField(NSLocalizedString("选项名称", comment: ""), text: $option.title)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let onDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("删除选项", comment: ""))
                }
                Button {
                    defaultOptionID = option.id
                } label: {
                    Image(systemName: defaultOptionID == option.id ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("设为默认", comment: ""))
            }
            RequestBodyPayloadEditor(
                payloadDisplayMode: payloadDisplayMode,
                payload: $option.payload
            )
        }
        .padding(.leading, 8)
    }
}

private struct RequestBodyPayloadEditor: View {
    let payloadDisplayMode: Model.RequestBodyOverrideMode
    @Binding var payload: [String: JSONValue]
    @State private var text: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch payloadDisplayMode {
            case .keyValue:
                RequestBodyPayloadKeyValueEditor(payload: $payload)
            case .rawJSON:
                textPayloadEditor(
                    title: NSLocalizedString("Value", comment: ""),
                    placeholder: NSLocalizedString("填写 JSON 对象", comment: ""),
                    lineLimit: 2...8
                )
            default:
                textPayloadEditor(
                    title: NSLocalizedString("Value", comment: ""),
                    placeholder: NSLocalizedString("payload，例如 thinking_budget = low", comment: ""),
                    lineLimit: 1...5
                )
            }
        }
    }

    private func textPayloadEditor(
        title: String,
        placeholder: String,
        lineLimit: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .etFont(.caption)
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(lineLimit)
                .etFont(.footnote.monospaced())
                .onAppear(perform: syncTextFromPayload)
                .onChange(of: text) { _, newValue in
                    parse(newValue)
                }
                .onChange(of: payloadDisplayMode) { _, _ in
                    syncTextFromPayload()
                }

            if let error {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func syncTextFromPayload() {
        switch payloadDisplayMode {
        case .rawJSON:
            text = ParameterExpressionParser.serializeRawJSONObject(parameters: payload)
        case .keyValue, .expression:
            text = ParameterExpressionParser.serialize(parameters: payload).joined(separator: "\n")
        @unknown default:
            text = ParameterExpressionParser.serialize(parameters: payload).joined(separator: "\n")
        }
    }

    private func parse(_ rawText: String) {
        do {
            switch payloadDisplayMode {
            case .rawJSON:
                payload = try ParameterExpressionParser.parseRawJSONObject(rawText)
            case .keyValue, .expression:
                let lines = rawText
                    .split(whereSeparator: \.isNewline)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let expressions = try lines.map { try ParameterExpressionParser.parse($0) }
                payload = ParameterExpressionParser.buildParameters(from: expressions)
            @unknown default:
                let lines = rawText
                    .split(whereSeparator: \.isNewline)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let expressions = try lines.map { try ParameterExpressionParser.parse($0) }
                payload = ParameterExpressionParser.buildParameters(from: expressions)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct RequestBodyPayloadKeyValueEntry: Identifiable, Equatable {
    let id: UUID
    var key: String
    var value: String
    var error: String?

    init(id: UUID = UUID(), key: String, value: String, error: String? = nil) {
        self.id = id
        self.key = key
        self.value = value
        self.error = error
    }
}

private struct RequestBodyPayloadKeyValueEditor: View {
    @Binding var payload: [String: JSONValue]
    @State private var entries: [RequestBodyPayloadKeyValueEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(entries) { entry in
                if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                    RequestBodyPayloadKeyValueRow(
                        entry: $entries[index],
                        canDelete: entries.count > 1,
                        onDelete: {
                            deleteEntry(withID: entry.id)
                        },
                        onChange: updatePayload
                    )
                }
            }

            Button {
                entries.append(RequestBodyPayloadKeyValueEntry(key: "", value: ""))
            } label: {
                Label(NSLocalizedString("添加键值对", comment: ""), systemImage: "plus")
            }
        }
        .onAppear(perform: syncEntriesFromPayload)
    }

    private func syncEntriesFromPayload() {
        let rows = payload
            .sorted(by: { $0.key < $1.key })
            .map { RequestBodyPayloadKeyValueEntry(key: $0.key, value: stringValue(for: $0.value)) }
        entries = rows.isEmpty ? [RequestBodyPayloadKeyValueEntry(key: "", value: "")] : rows
    }

    private func updatePayload() {
        var updatedEntries = entries
        var parsedExpressions: [ParameterExpressionParser.ParsedExpression] = []
        var hasError = false

        for index in updatedEntries.indices {
            do {
                if let expression = try parseEntry(updatedEntries[index]) {
                    parsedExpressions.append(expression)
                }
                updatedEntries[index].error = nil
            } catch {
                hasError = true
                updatedEntries[index].error = error.localizedDescription
            }
        }

        entries = updatedEntries
        guard !hasError else { return }
        payload = ParameterExpressionParser.buildParameters(from: parsedExpressions)
    }

    private func parseEntry(_ entry: RequestBodyPayloadKeyValueEntry) throws -> ParameterExpressionParser.ParsedExpression? {
        let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty && value.isEmpty {
            return nil
        }
        guard !key.isEmpty else {
            throw ParameterExpressionParser.ParserError.invalidKey
        }
        if value.isEmpty {
            return ParameterExpressionParser.ParsedExpression(key: key, value: .string(""))
        }
        return try ParameterExpressionParser.parse("\(key) = \(entry.value)")
    }

    private func deleteEntry(withID id: UUID) {
        entries.removeAll { $0.id == id }
        if entries.isEmpty {
            entries.append(RequestBodyPayloadKeyValueEntry(key: "", value: ""))
        }
        updatePayload()
    }

    private func stringValue(for value: JSONValue) -> String {
        switch value {
        case .string(let string):
            return string
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .dictionary, .array, .null:
            return value.prettyPrintedCompact()
        }
    }
}

private struct RequestBodyPayloadKeyValueRow: View {
    @Binding var entry: RequestBodyPayloadKeyValueEntry
    let canDelete: Bool
    let onDelete: () -> Void
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Key", comment: ""))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                    TextField(NSLocalizedString("Key", comment: ""), text: $entry.key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .etFont(.footnote.monospaced())
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if canDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("删除", comment: ""))
                }
            }

            Text(NSLocalizedString("Value", comment: ""))
                .etFont(.caption)
                .foregroundStyle(.secondary)
            TextField(NSLocalizedString("Value", comment: ""), text: $entry.value, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...4)
                .etFont(.footnote.monospaced())

            if let error = entry.error {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: entry.key) { _, _ in onChange() }
        .onChange(of: entry.value) { _, _ in onChange() }
    }
}

private struct KeyValueRow: View {
    @Binding var entry: ModelSettingsView.KeyValueEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("Key", comment: ""))
                .etFont(.caption)
                .foregroundStyle(.secondary)
            TextField(NSLocalizedString("Key", comment: ""), text: $entry.key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .etFont(.body.monospaced())

            Text(NSLocalizedString("Value", comment: ""))
                .etFont(.caption)
                .foregroundStyle(.secondary)
            TextField(NSLocalizedString("Value", comment: ""), text: $entry.value, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...4)
                .etFont(.body.monospaced())

            if let error = entry.error {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
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
