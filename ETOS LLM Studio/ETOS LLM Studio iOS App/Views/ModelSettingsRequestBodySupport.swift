// ============================================================================
// ModelSettingsRequestBodySupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 iOS 模型设置页的请求体编辑状态、结构化控制与预览 payload 构造。
// ============================================================================

import SwiftUI
import Foundation
import Combine
import ETOSCore

extension ModelSettingsView {
    func loadEditorState() {
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

    func addKeyValueEntry() {
        keyValueEntries.append(KeyValueEntry(key: "", value: ""))
    }

    func deleteKeyValueEntries(at offsets: IndexSet) {
        keyValueEntries.remove(atOffsets: offsets)
        if keyValueEntries.isEmpty {
            addKeyValueEntry()
        }
    }

    func validateKeyValueEntry(withId id: UUID) {
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

    func addEmptyEntry() {
        expressionEntries.append(ExpressionEntry(text: ""))
    }

    func deleteEntries(at offsets: IndexSet) {
        expressionEntries.remove(atOffsets: offsets)
        if expressionEntries.isEmpty {
            addEmptyEntry()
        }
    }

    func validateEntry(withId id: UUID) {
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

    func saveEditorState() {
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

    var requestBodyPreview: RequestBodyPreview {
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
        let serialized = ParameterExpressionParser.serialize(parameters: ["value": value]).first ?? "value="
        guard let separatorIndex = serialized.firstIndex(of: "=") else {
            return serialized
        }
        return String(serialized[serialized.index(after: separatorIndex)...])
    }

    func validateRawJSON(_ rawJSON: String) {
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
    var structuredControlsSection: some View {
        Section(
            header: Text(NSLocalizedString("结构化控制", comment: "")),
            footer: Text(NSLocalizedString("这些控制会在发送时覆盖上面的自定义Body，适合思考预算、搜索、温度等常切参数。", comment: ""))
        ) {
            if model.requestBodyControls.isEmpty {
                Text(NSLocalizedString("暂无", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(requestBodyControlsBinding, id: \.id, editActions: .move) { $control in
                    let controlID = control.id
                    NavigationLink {
                        RequestBodyControlDetailView(
                            control: $control,
                            payloadDisplayMode: requestBodyMode,
                            onSplit: { splitControls in
                                replaceRequestBodyControl(withID: controlID, with: splitControls)
                            }
                        )
                    } label: {
                        RequestBodyControlRow(control: control)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteRequestBodyControl(withID: controlID)
                        } label: {
                            Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                        }
                    }
                }
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

            Button {
                presentRequestBodyControlImport()
            } label: {
                Label(NSLocalizedString("从其他模型导入", comment: ""), systemImage: "square.and.arrow.down")
            }
        }
    }

    private func presentRequestBodyControlImport() {
        var sourceProviders = ChatService.shared.providersSubject.value.filter { $0.id != provider.id }
        sourceProviders.insert(provider, at: 0)
        requestBodyControlImportSources = sourceProviders.flatMap { sourceProvider in
            sourceProvider.models.compactMap { sourceModel in
                guard !(sourceProvider.id == provider.id && sourceModel.id == model.id),
                      !sourceModel.requestBodyControls.isEmpty else {
                    return nil
                }
                return RunnableModel(provider: sourceProvider, model: sourceModel)
            }
        }
        isRequestBodyControlImportPresented = true
    }

    private func addToggleControl() {
        model.requestBodyControls.append(
            ModelRequestBodyControlDefaults.initialToggleControl(existingControls: model.requestBodyControls)
        )
    }

    private var requestBodyControlsBinding: Binding<[ModelRequestBodyControl]> {
        Binding(
            get: { model.requestBodyControls },
            set: { model.requestBodyControls = $0 }
        )
    }

    private func addOptionGroupControl() {
        model.requestBodyControls.append(
            ModelRequestBodyControlDefaults.initialOptionGroupControl(
                existingControls: model.requestBodyControls,
                apiFormat: provider.apiFormat
            )
        )
    }

    private func deleteRequestBodyControl(withID controlID: String) {
        guard let index = model.requestBodyControls.firstIndex(where: { $0.id == controlID }) else { return }
        model.requestBodyControls.remove(at: index)
    }

    private func replaceRequestBodyControl(
        withID controlID: String,
        with splitControls: [ModelRequestBodyControl]
    ) {
        guard let index = model.requestBodyControls.firstIndex(where: { $0.id == controlID }) else { return }
        model.requestBodyControls.replaceSubrange(index...index, with: splitControls)
    }

    private func buildRequestPreviewPayload(
        apiFormat: String,
        model: Model,
        overrides: [String: JSONValue]
    ) -> [String: Any] {
        let overridesAny = overrides.mapValues { $0.toAny() }

        switch ProviderAPIFormatFamily(apiFormat: apiFormat) {
        case .gemini:
            var payload: [String: Any] = [:]
            payload["contents"] = [
                [
                    "role": "user",
                    "parts": [
                        ["text": "<message>"]
                    ]
                ]
            ]
            return mergedPreviewRequestPayload(payload, with: overridesAny)

        case .anthropic:
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
            if let thinking = overridesAny["thinking"] as? [String: Any] {
                payload["thinking"] = thinking
            } else if let thinkingBudget = overridesAny["thinking_budget"] {
                payload["thinking"] = [
                    "type": "enabled",
                    "budget_tokens": thinkingBudget
                ]
            }
            if let effort = overridesAny["effort"] {
                payload["effort"] = effort
            }
            return mergedPreviewRequestPayload(payload, with: passthroughAnthropicPreviewOverrides(overridesAny))

        case .openAIResponses:
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

    private func mergedPreviewRequestPayload(_ base: [String: Any], with overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, overlayValue) in overlay {
            if let baseDictionary = result[key] as? [String: Any],
               let overlayDictionary = overlayValue as? [String: Any] {
                result[key] = mergedPreviewRequestPayload(baseDictionary, with: overlayDictionary)
            } else if let baseArray = result[key] as? [Any],
                      let overlayArray = overlayValue as? [Any] {
                result[key] = baseArray + overlayArray
            } else {
                result[key] = overlayValue
            }
        }
        return result
    }

    private func passthroughAnthropicPreviewOverrides(_ overrides: [String: Any]) -> [String: Any] {
        overrides.filter { $0.key != "thinking_budget" }
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
}
