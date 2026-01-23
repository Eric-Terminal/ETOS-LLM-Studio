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
import Foundation
import Shared

struct ProviderDetailView: View {
    @State var provider: Provider
    @State private var isAddingModel = false
    @State private var isFetchingModels = false
    @State private var fetchError: String?
    @State private var showErrorAlert = false
    @State private var hasAutoFetchedModels = false
    
    var body: some View {
        let activeIndices = activeModelIndices()
        let inactiveIndices = inactiveModelIndices()

        ZStack {
            List {
                Section("已激活") {
                    if activeIndices.isEmpty {
                        Text("暂无已激活模型")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(activeIndices, id: \.self) { index in
                            modelRow(for: index, isActive: true)
                        }
                        .onDelete { offsets in
                            deleteModels(at: offsets, in: activeIndices)
                        }
                    }
                }

                Section("未激活") {
                    if inactiveIndices.isEmpty {
                        Text("暂无未激活模型")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(inactiveIndices, id: \.self) { index in
                            modelRow(for: index, isActive: false)
                        }
                    }
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
        .task {
            guard !hasAutoFetchedModels, !isFetchingModels else { return }
            hasAutoFetchedModels = true
            await fetchAndMergeModels()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { isAddingModel = true }) {
                    Image(systemName: "plus")
                }
            }
            
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Button(action: { Task { await fetchAndMergeModels() } }) {
                        Image(systemName: "icloud.and.arrow.down")
                    }
                    .disabled(isFetchingModels)
                    Spacer()
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
    
    private func deleteModels(at offsets: IndexSet, in indices: [Int]) {
        let mappedOffsets = IndexSet(offsets.compactMap { offset in
            indices.indices.contains(offset) ? indices[offset] : nil
        })
        provider.models.remove(atOffsets: mappedOffsets)
    }
    
    private func saveChanges() {
        var providerToSave = provider
        providerToSave.models = provider.models.filter { $0.isActivated }
        
        ConfigLoader.saveProvider(providerToSave)
        ChatService.shared.reloadProviders()
    }

    private func activeModelIndices() -> [Int] {
        provider.models.indices.filter { provider.models[$0].isActivated }
    }

    private func inactiveModelIndices() -> [Int] {
        provider.models.indices.filter { !provider.models[$0].isActivated }
    }

    @ViewBuilder
    private func modelRow(for index: Int, isActive: Bool) -> some View {
        if isActive {
            NavigationLink(destination: ModelSettingsView(model: $provider.models[index])) {
                Text(provider.models[index].displayName)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(provider.models[index].displayName)
                    Spacer()
                    if !isActive {
                        Button {
                            provider.models[index].isActivated = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("激活模型")
                    }
                }
            }
        }
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
