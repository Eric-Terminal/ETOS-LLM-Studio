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
    
    // 手表端也复用表达式编辑逻辑，保持与 iPhone 一致的覆盖策略
    @State private var expressionEntries: [ExpressionEntry] = []
    
    var body: some View {
        Form {
            Section(header: Text("参数表达式")) {
                ForEach($expressionEntries) { $entry in
                    ExpressionRow(entry: $entry)
                        .onChange(of: entry.text, initial: false) { _, _ in
                            validateEntry(withId: entry.id)
                        }
                }
                .onDelete(perform: deleteEntries)
                
                Button {
                    addEmptyEntry()
                } label: {
                    Label("添加", systemImage: "plus")
                }
            }
            
            Section(header: Text("写法提示")) {
                Text("使用 key = value 格式，例如 thinking_budget = 128")
                Text("嵌套用 { }，例如 chat_template_kwargs = {thinking = false}")
            }
        }
        .navigationTitle(model.displayName)
        .onAppear(perform: loadExpressions)
        .onDisappear(perform: saveExpressions)
    }
}

// MARK: - 内部状态

extension ModelBehaviorSettingsView {
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
        
        guard !hasError else {
            return
        }
        
        let merged = ParameterExpressionParser.buildParameters(from: parsedExpressions)
        model.overrideParameters = merged
        onSave()
    }
}

// MARK: - 子视图

private struct ExpressionRow: View {
    @Binding var entry: ModelBehaviorSettingsView.ExpressionEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("比如 temperature = 0.8", text: $entry.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            
            if let error = entry.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
