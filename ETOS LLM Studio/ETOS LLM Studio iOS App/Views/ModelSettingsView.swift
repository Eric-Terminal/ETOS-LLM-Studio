import SwiftUI
import Shared

struct ModelSettingsView: View {
    @Binding var model: Model
    let onSave: () -> Void
    @State private var expressionEntries: [ExpressionEntry] = []

    init(model: Binding<Model>, onSave: @escaping () -> Void = {}) {
        _model = model
        self.onSave = onSave
    }
    
    var body: some View {
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
}

// MARK: - 子视图

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
