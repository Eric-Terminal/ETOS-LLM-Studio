// ============================================================================
// BuiltInPromptSettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 内置提示词模板设置页。使用扁平化列表，适配小屏幕。
// ============================================================================

import SwiftUI
import ETOSCore

struct BuiltInPromptSettingsView: View {
    var body: some View {
        BuiltInPromptOverviewListView()
            .navigationTitle(NSLocalizedString("提示词设置", comment: "Built-in prompt settings title"))
    }
}

private struct BuiltInPromptOverviewListView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading) {
                    Label(NSLocalizedString("提示词模板", comment: "Built-in prompt intro title"), systemImage: "curlybraces")
                        .font(.headline)
                    Text(NSLocalizedString("未自定义时会使用当前语言的内置模板；保存内容与默认模板一致时会自动恢复为默认，不写入数据库。", comment: "Built-in prompt intro text"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(BuiltInPromptCategory.allCases) { category in
                    NavigationLink {
                        BuiltInPromptCategoryListView(category: category)
                    } label: {
                        Label(category.title, systemImage: category.systemImageName)
                    }
                }
            } header: {
                Text(NSLocalizedString("分类", comment: "Built-in prompt settings section"))
            }
        }
    }
}

private struct BuiltInPromptCategoryListView: View {
    let category: BuiltInPromptCategory
    @State private var prompts: [BuiltInPromptSnapshot] = []

    var body: some View {
        List {
            Section {
                ForEach(prompts) { prompt in
                    NavigationLink {
                        BuiltInPromptEditorView(promptID: prompt.id)
                    } label: {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(prompt.title)
                                Spacer()
                                Text(prompt.isCustomized ? NSLocalizedString("自定义", comment: "Built-in prompt customized status") : NSLocalizedString("默认", comment: "Built-in prompt default status"))
                                    .font(.caption)
                                    .foregroundStyle(prompt.isCustomized ? .blue : .secondary)
                            }
                            Text(prompt.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            } footer: {
                Text(NSLocalizedString("变量形如 {time}、{memory}，发送给模型前会自动替换为本次请求的真实内容。", comment: "Built-in prompt variable footer"))
            }
        }
        .navigationTitle(category.title)
        .task {
            await reload()
        }
    }

    private func reload() async {
        let category = category
        let loaded = await Task.detached(priority: .utility) {
            BuiltInPromptStore.snapshots(in: category)
        }.value
        prompts = loaded
    }
}

private struct BuiltInPromptEditorView: View {
    let promptID: BuiltInPromptID
    @State private var snapshot: BuiltInPromptSnapshot?
    @State private var draft = ""
    @State private var isSaving = false
    @State private var statusText: String?

    var body: some View {
        Form {
            if let snapshot {
                Section {
                    VStack(alignment: .leading) {
                        Text(snapshot.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Label(snapshot.isCustomized ? NSLocalizedString("自定义", comment: "Built-in prompt customized status") : NSLocalizedString("默认", comment: "Built-in prompt default status"), systemImage: snapshot.isCustomized ? "pencil" : "checkmark.seal")
                                .font(.caption)
                                .foregroundStyle(snapshot.isCustomized ? .blue : .secondary)
                            Spacer()
                        }
                    }
                }

                Section {
                    TextField(NSLocalizedString("模板", comment: "Built-in prompt editor section"), text: $draft.watchKeyboardNewlineBinding(), axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(5...10)
                        .autocorrectionDisabled()
                } header: {
                    Text(NSLocalizedString("模板", comment: "Built-in prompt editor section"))
                } footer: {
                    Text(NSLocalizedString("保存为空会发送空模板；保存为当前默认内容会恢复默认并删除自定义记录。", comment: "Built-in prompt editor footer"))
                }

                if !snapshot.variables.isEmpty {
                    Section {
                        ForEach(snapshot.variables) { variable in
                            VStack(alignment: .leading) {
                                Text(variable.token)
                                    .font(.system(.body, design: .monospaced))
                                Text(variable.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text(NSLocalizedString("可用变量", comment: "Built-in prompt variables section"))
                    }
                }

                Section {
                    VStack(alignment: .leading) {
                        Text(snapshot.defaultTemplate)
                            .font(.system(.footnote, design: .monospaced))
                    }
                } header: {
                    Text(NSLocalizedString("当前语言默认模板", comment: "Built-in prompt default template section"))
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Label(NSLocalizedString("保存", comment: "Built-in prompt save button"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(isSaving)

                    Button(role: .destructive) {
                        reset()
                    } label: {
                        Label(NSLocalizedString("恢复默认", comment: "Built-in prompt reset button"), systemImage: "arrow.counterclockwise")
                    }
                    .disabled(isSaving)
                }

                if let statusText {
                    Section {
                        Text(statusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    ProgressView()
                }
            }
        }
        .navigationTitle(snapshot?.title ?? NSLocalizedString("提示词", comment: "Built-in prompt editor title"))
        .task {
            await reload()
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(isSaving || snapshot == nil)
                .accessibilityLabel(NSLocalizedString("保存", comment: "Built-in prompt save button"))
            }
        }
    }

    private func reload() async {
        let promptID = promptID
        let loaded = await Task.detached(priority: .utility) {
            BuiltInPromptStore.snapshot(for: promptID)
        }.value
        snapshot = loaded
        draft = loaded.currentTemplate
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        statusText = nil
        let promptID = promptID
        let draft = draft
        Task {
            let didSave = await Task.detached(priority: .utility) {
                BuiltInPromptStore.saveTemplate(draft, for: promptID)
            }.value
            let loaded = await Task.detached(priority: .utility) {
                BuiltInPromptStore.snapshot(for: promptID)
            }.value
            snapshot = loaded
            self.draft = loaded.currentTemplate
            statusText = didSave
                ? NSLocalizedString("已保存提示词设置。", comment: "Built-in prompt saved status")
                : NSLocalizedString("提示词设置未发生变化。", comment: "Built-in prompt unchanged status")
            isSaving = false
        }
    }

    private func reset() {
        guard !isSaving else { return }
        isSaving = true
        statusText = nil
        let promptID = promptID
        Task {
            _ = await Task.detached(priority: .utility) {
                BuiltInPromptStore.resetTemplate(for: promptID)
            }.value
            let loaded = await Task.detached(priority: .utility) {
                BuiltInPromptStore.snapshot(for: promptID)
            }.value
            snapshot = loaded
            draft = loaded.currentTemplate
            statusText = NSLocalizedString("已恢复默认提示词。", comment: "Built-in prompt reset status")
            isSaving = false
        }
    }
}

// MARK: - watchOS TextField 换行支持

fileprivate extension String {
    func watchKeyboardEscapedNewlines() -> String {
        replacingOccurrences(of: "\n", with: "\\n")
    }

    func watchKeyboardUnescapedNewlines() -> String {
        replacingOccurrences(of: "\\n", with: "\n")
    }
}

fileprivate extension Binding where Value == String {
    func watchKeyboardNewlineBinding() -> Binding<String> {
        Binding(
            get: { wrappedValue.watchKeyboardEscapedNewlines() },
            set: { newValue in
                let unescaped = newValue.watchKeyboardUnescapedNewlines()
                guard unescaped != wrappedValue else { return }
                wrappedValue = unescaped
            }
        )
    }
}
