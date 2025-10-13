// ============================================================================
// ModelBehaviorSettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 模型行为设置视图
//
// 定义内容:
// - 允许用户为特定模型覆盖常用的 API 参数
// - 例如: max_tokens, top_k, enable_thinking 等
// ============================================================================

import SwiftUI
import Shared

struct ModelBehaviorSettingsView: View {
    @Binding var model: Model
    let onSave: () -> Void
    
    // 用于编辑覆盖参数的中间状态
    @State private var maxTokens: String = ""
    @State private var topK: String = ""
    @State private var frequencyPenalty: String = ""
    @State private var presencePenalty: String = ""
    @State private var enableThinking: Bool = false
    @State private var thinkingBudget: String = ""
    
    var body: some View {
        Form {
            Section(header: Text("常用参数覆盖")) {
                Toggle("启用思考过程", isOn: $enableThinking)
                
                HStack(spacing: 15) {
                    MarqueeText(content: "max_tokens")
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("", text: $maxTokens)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
                
                HStack(spacing: 15) {
                    MarqueeText(content: "top_k")
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("", text: $topK)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
                
                HStack(spacing: 15) {
                    MarqueeText(content: "frequency_penalty")
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("", text: $frequencyPenalty)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
                
                HStack(spacing: 15) {
                    MarqueeText(content: "presence_penalty")
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("", text: $presencePenalty)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }

                HStack(spacing: 15) {
                    MarqueeText(content: "thinking_budget")
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("", text: $thinkingBudget)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
            }
        }
        .navigationTitle(model.displayName)
        .onAppear(perform: loadParameters)
        .onDisappear {
            saveParameters()
        }
    }
    
    private func loadParameters() {
        // 加载 max_tokens
        if case let .int(value) = model.overrideParameters["max_tokens"] {
            self.maxTokens = String(value)
        } else {
            self.maxTokens = ""
        }
        
        // 加载 top_k
        if case let .int(value) = model.overrideParameters["top_k"] {
            self.topK = String(value)
        } else {
            self.topK = ""
        }
        
        // 加载 frequency_penalty
        if case let .double(value) = model.overrideParameters["frequency_penalty"] {
            self.frequencyPenalty = String(value)
        } else {
            self.frequencyPenalty = ""
        }
        
        // 加载 presence_penalty
        if case let .double(value) = model.overrideParameters["presence_penalty"] {
            self.presencePenalty = String(value)
        } else {
            self.presencePenalty = ""
        }
        
        // 加载 enable_thinking
        if case let .bool(value) = model.overrideParameters["enable_thinking"] {
            self.enableThinking = value
        } else {
            self.enableThinking = false
        }

        // 加载 thinking_budget
        if case let .int(value) = model.overrideParameters["thinking_budget"] {
            self.thinkingBudget = String(value)
        } else {
            self.thinkingBudget = ""
        }
    }
    
    private func saveParameters() {
        // 保存 max_tokens
        if let intValue = Int(maxTokens), intValue > 0 {
            model.overrideParameters["max_tokens"] = .int(intValue)
        } else {
            model.overrideParameters.removeValue(forKey: "max_tokens")
        }
        
        // 保存 top_k
        if let intValue = Int(topK), intValue > 0 {
            model.overrideParameters["top_k"] = .int(intValue)
        } else {
            model.overrideParameters.removeValue(forKey: "top_k")
        }
        
        // 保存 frequency_penalty
        if let doubleValue = Double(frequencyPenalty) {
            model.overrideParameters["frequency_penalty"] = .double(doubleValue)
        } else {
            model.overrideParameters.removeValue(forKey: "frequency_penalty")
        }
        
        // 保存 presence_penalty
        if let doubleValue = Double(presencePenalty) {
            model.overrideParameters["presence_penalty"] = .double(doubleValue)
        } else {
            model.overrideParameters.removeValue(forKey: "presence_penalty")
        }
        
        // 保存 enable_thinking
        if enableThinking {
            model.overrideParameters["enable_thinking"] = .bool(true)
        } else {
            model.overrideParameters.removeValue(forKey: "enable_thinking")
        }

        // 保存 thinking_budget
        if let intValue = Int(thinkingBudget), intValue > 0 {
            model.overrideParameters["thinking_budget"] = .int(intValue)
        } else {
            model.overrideParameters.removeValue(forKey: "thinking_budget")
        }
        
        // 通知上层视图执行保存操作
        onSave()
    }
}
