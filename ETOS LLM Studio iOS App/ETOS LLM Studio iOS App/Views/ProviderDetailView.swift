// ============================================================================
// ProviderDetailView.swift
// ============================================================================
// ETOS LLM Studio Watch App 提供商详情视图
//
// 定义内容:
// - 显示一个提供商下的所有模型
// - 允许用户激活/禁用模型、添加新模型、从云端获取模型列表
// ============================================================================

import SwiftUI
import Shared

struct ProviderDetailView: View {
    @State var provider: Provider
    @State private var isAddingModel = false
    @State private var isFetchingModels = false
    @State private var fetchError: String?
    @State private var showErrorAlert = false
    @State private var isInEditMode = false
    
    var body: some View {
        ZStack {
            List {
                ForEach($provider.models) { $model in
                    if isInEditMode {
                        NavigationLink(destination: ModelSettingsView(model: $model)) {
                            Text(model.displayName)
                        }
                    } else {
                        HStack {
                            // 导航到设置是次要操作，主要操作是开关
                            NavigationLink(destination: ModelSettingsView(model: $model)) {
                                Text(model.displayName)
                            }
                            Spacer()
                            Toggle("激活", isOn: $model.isActivated)
                                .labelsHidden()
                        }
                    }
                }
                .onDelete(perform: deleteModel)
            }
            
            if isFetchingModels {
                ProgressView("正在获取...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.4))
                    .edgesIgnoringSafeArea(.all)
            }
        }
        .navigationTitle(provider.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    Button(action: { Task { await fetchAndMergeModels() } }) {
                        Image(systemName: "icloud.and.arrow.down")
                    }
                    .disabled(isFetchingModels)
                    
                    Button(action: { isAddingModel = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingModel) {
            ModelAddView(provider: $provider)
        }
        .onChange(of: provider) {
            saveChanges()
        }
        .alert("获取模型失败", isPresented: $showErrorAlert) {
            Button("好的") { }
        } message: {
            Text(fetchError ?? "发生未知错误。")
        }
    }
    
    private func fetchAndMergeModels() async {
        isFetchingModels = true
        defer { isFetchingModels = false }
        
        do {
            let fetchedModels = try await ChatService.shared.fetchModels(for: provider)
            
            let existingModelNames = Set(provider.models.map { $0.modelName })
            
            for fetchedModel in fetchedModels {
                if !existingModelNames.contains(fetchedModel.modelName) {
                    provider.models.append(fetchedModel)
                }
            }
            
        } catch {
            fetchError = error.localizedDescription
            showErrorAlert = true
        }
    }
    
    private func deleteModel(at offsets: IndexSet) {
        provider.models.remove(atOffsets: offsets)
    }
    
    private func saveChanges() {
        var providerToSave = provider
        providerToSave.models = provider.models.filter { $0.isActivated }
        
        ConfigLoader.saveProvider(providerToSave)
        ChatService.shared.reloadProviders()
    }
}

// 一个用于添加新模型的简单视图
private struct ModelAddView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var provider: Provider
    @State private var modelName: String = ""
    @State private var displayName: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("新模型信息")) {
                    TextField("模型 ID (e.g., gpt-4o)", text: $modelName)
                    TextField("显示名称 (可选)", text: $displayName)
                }
                Section {
                    Button("添加模型") {
                        addModel()
                    }
                    .disabled(modelName.isEmpty)
                }
            }
            .navigationTitle("添加模型")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
    
    private func addModel() {
        let newModel = Model(
            modelName: modelName,
            displayName: displayName.isEmpty ? modelName : displayName
        )
        provider.models.append(newModel)
        dismiss()
    }
}