import SwiftUI
import Shared

struct ModelBehaviorSettingsView: View {
    @Binding var model: Model
    let onSave: () -> Void
    
    // 这里使用表达式列表来管理覆盖参数，每条表达式形如:
    // thinking_budget = 128
    @State private var expressionEntries: [ExpressionEntry] = []
    
    var body: some View {
        Form {
            Section("参数表达式") {
                ForEach($expressionEntries) { $entry in
                    ExpressionRow(entry: $entry, onDelete: { deleteEntry(entry.id) })
                        .onChange(of: entry.text) { _ in
                            validateEntry(withId: entry.id)
                        }
                }
                
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
    
    private func deleteEntry(_ id: UUID) {
        expressionEntries.removeAll { $0.id == id }
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
            // 保持原有参数不动，避免损坏已生效配置
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
    let onDelete: () -> Void
    
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
            
            HStack {
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .tint(.red)
            }
        }
    }
}
