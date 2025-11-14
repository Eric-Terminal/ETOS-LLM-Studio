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
    @State private var pendingDeleteOffsets: IndexSet?
    @State private var showDeleteModelConfirm = false
    
    var body: some View {
        ZStack {
            List {
                if isInEditMode {
                    ForEach($provider.models) { $model in
                        NavigationLink(destination: ModelSettingsView(model: $model)) {
                            Text(model.displayName)
                        }
                    }
                    .onDelete(perform: prepareDeleteModel)
                } else {
                    ForEach($provider.models) { $model in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(model.displayName)
                                Spacer()
                                Toggle("激活", isOn: $model.isActivated)
                                    .labelsHidden()
                            }
                        }
                    }
                    .onDelete(perform: prepareDeleteModel)
                }
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
                Button(action: { isAddingModel = true }) {
                    Image(systemName: "plus")
                }
            }
            
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Button(action: { isInEditMode.toggle() }) {
                        Image(systemName: isInEditMode ? "checkmark.circle.fill" : "pencil")
                    }
                    
                    Spacer()
                    
                    Button(action: { Task { await fetchAndMergeModels() } }) {
                        Image(systemName: "icloud.and.arrow.down")
                    }
                    .disabled(isFetchingModels)
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
        .alert("确认删除模型", isPresented: $showDeleteModelConfirm) {
            Button("删除", role: .destructive) {
                performDeleteModel()
            }
            Button("取消", role: .cancel) {
                pendingDeleteOffsets = nil
            }
        } message: {
            Text(deleteModelWarningMessage())
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
    
    private func prepareDeleteModel(at offsets: IndexSet) {
        pendingDeleteOffsets = offsets
        showDeleteModelConfirm = true
    }
    
    private func performDeleteModel() {
        guard let offsets = pendingDeleteOffsets else { return }
        provider.models.remove(atOffsets: offsets)
        pendingDeleteOffsets = nil
    }
    
    private func deleteModelWarningMessage() -> String {
        guard let offsets = pendingDeleteOffsets else {
            return "删除后无法恢复这些模型。"
        }
        let names = offsets.compactMap { index -> String? in
            guard provider.models.indices.contains(index) else { return nil }
            return provider.models[index].displayName
        }
        if names.isEmpty {
            return "删除后无法恢复这些模型。"
        } else {
            return "您将删除以下模型：\(names.joined(separator: "、"))。此操作无法撤销。"
        }
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
                    TextField("模型ID (e.g., gpt-4o)", text: $modelName)
                    TextField("模型名称 (可选)", text: $displayName)
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
