import SwiftUI
import Foundation
import Shared

struct ModelSettingsView: View {
    @Binding var model: Model
    let provider: Provider
    let onSave: () -> Void
    @State private var expressionEntries: [ExpressionEntry] = []

    init(model: Binding<Model>, provider: Provider, onSave: @escaping () -> Void = {}) {
        _model = model
        self.provider = provider
        self.onSave = onSave
    }
    
    var body: some View {
        let preview = requestBodyPreview

        Form {
            Section(
                header: Text("基础信息"),
                footer: Text("模型ID是 API 调用时使用的真实标识，模型名称是 App 内展示给用户的别名。")
            ) {
                TextField("模型名称", text: $model.displayName)
                TextField("模型ID", text: $model.modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
            }

            Section("模型能力") {
                Toggle("聊天", isOn: capabilityBinding(.chat))
                Toggle("语音转文字", isOn: capabilityBinding(.speechToText))
                Toggle("嵌入", isOn: capabilityBinding(.embedding))
                Toggle("生图", isOn: capabilityBinding(.imageGeneration))
            }
            
            Section("参数表达式") {
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
                    Label("添加表达式", systemImage: "plus")
                }
            }
            
            Section("表达式说明") {
                Label("用 = 指定参数，比如: thinking_budget = 128", systemImage: "character.cursor.ibeam")
                Label("嵌套结构使用 {}，例如: chat_template_kwargs = {thinking = false}", systemImage: "curlybraces")
                Label("重复 key 会自动合并字典，方便拆分输入", systemImage: "square.stack.3d.up")
            }

            Section("请求体预览") {
                Text(preview.text)
                    .font(.footnote.monospaced())
                    .foregroundStyle(preview.isPlaceholder ? .secondary : .primary)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("模型信息")
        .onAppear(perform: loadExpressions)
        .onDisappear(perform: saveExpressions)
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
    
    private func loadExpressions() {
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
    
    private func saveExpressions() {
        var updatedEntries = expressionEntries
        var parsedExpressions: [ParameterExpressionParser.ParsedExpression] = []
        var hasError = false
        
        for index in updatedEntries.indices {
            let trimmed = updatedEntries[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                updatedEntries[index].error = nil
                continue
            }
            
            do {
                let parsed = try ParameterExpressionParser.parse(trimmed)
                parsedExpressions.append(parsed)
                updatedEntries[index].error = nil
            } catch {
                updatedEntries[index].error = error.localizedDescription
                hasError = true
            }
        }
        
        expressionEntries = updatedEntries
        
        if !hasError {
            let merged = ParameterExpressionParser.buildParameters(from: parsedExpressions)
            model.overrideParameters = merged
        }
        onSave()
    }

    private var requestBodyPreview: RequestBodyPreview {
        let result = previewOverrideParameters()
        if result.hasError {
            return RequestBodyPreview(
                text: NSLocalizedString("表达式有误，无法预览", comment: ""),
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
        var parsedExpressions: [ParameterExpressionParser.ParsedExpression] = []
        var hasError = false

        for entry in expressionEntries {
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            do {
                let parsed = try ParameterExpressionParser.parse(trimmed)
                parsedExpressions.append(parsed)
            } catch {
                hasError = true
            }
        }

        let parameters = ParameterExpressionParser.buildParameters(from: parsedExpressions)
        return (parameters: parameters, hasError: hasError)
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
            var payload = overridesAny
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
                let ordered: [Model.Capability] = [.chat, .speechToText, .embedding, .imageGeneration]
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
            TextField("参数表达式，比如 temperature = 0.8", text: $entry.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
            
            if let error = entry.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
