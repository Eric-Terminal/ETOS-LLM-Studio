import SwiftUI
import Shared

struct ModelBehaviorSettingsView: View {
    @Binding var model: Model
    let onSave: () -> Void
    
    @State private var maxTokens: String = ""
    @State private var topK: String = ""
    @State private var frequencyPenalty: String = ""
    @State private var presencePenalty: String = ""
    @State private var enableThinking: Bool = false
    @State private var thinkingBudget: String = ""
    
    var body: some View {
        Form {
            Section("参数覆盖") {
                Toggle("启用思考过程", isOn: $enableThinking)
                
                parameterRow(label: "max_tokens", text: $maxTokens)
                parameterRow(label: "top_k", text: $topK)
                parameterRow(label: "frequency_penalty", text: $frequencyPenalty)
                parameterRow(label: "presence_penalty", text: $presencePenalty)
                parameterRow(label: "thinking_budget", text: $thinkingBudget)
            }
        }
        .navigationTitle(model.displayName)
        .onAppear(perform: loadParameters)
        .onDisappear(perform: saveParameters)
    }
    
    private func parameterRow(label: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField("", text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(width: 100)
        }
    }
    
    private func loadParameters() {
        if case let .int(value) = model.overrideParameters["max_tokens"] { maxTokens = String(value) }
        if case let .int(value) = model.overrideParameters["top_k"] { topK = String(value) }
        if case let .double(value) = model.overrideParameters["frequency_penalty"] { frequencyPenalty = String(value) }
        if case let .double(value) = model.overrideParameters["presence_penalty"] { presencePenalty = String(value) }
        if case let .bool(value) = model.overrideParameters["enable_thinking"] { enableThinking = value }
        if case let .int(value) = model.overrideParameters["thinking_budget"] { thinkingBudget = String(value) }
    }
    
    private func saveParameters() {
        if let value = Int(maxTokens), value > 0 {
            model.overrideParameters["max_tokens"] = .int(value)
        } else {
            model.overrideParameters.removeValue(forKey: "max_tokens")
        }
        
        if let value = Int(topK), value > 0 {
            model.overrideParameters["top_k"] = .int(value)
        } else {
            model.overrideParameters.removeValue(forKey: "top_k")
        }
        
        if let value = Double(frequencyPenalty) {
            model.overrideParameters["frequency_penalty"] = .double(value)
        } else {
            model.overrideParameters.removeValue(forKey: "frequency_penalty")
        }
        
        if let value = Double(presencePenalty) {
            model.overrideParameters["presence_penalty"] = .double(value)
        } else {
            model.overrideParameters.removeValue(forKey: "presence_penalty")
        }
        
        if enableThinking {
            model.overrideParameters["enable_thinking"] = .bool(true)
        } else {
            model.overrideParameters.removeValue(forKey: "enable_thinking")
        }
        
        if let value = Int(thinkingBudget), value > 0 {
            model.overrideParameters["thinking_budget"] = .int(value)
        } else {
            model.overrideParameters.removeValue(forKey: "thinking_budget")
        }
        
        onSave()
    }
}
