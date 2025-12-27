import SwiftUI
import Foundation
import Shared

struct ProviderDetailView: View {
    @State var provider: Provider
    @State private var isAddingModel = false
    @State private var isFetchingModels = false
    @State private var fetchError: String?
    @State private var showErrorAlert = false
    @State private var isEditingModels = false
    @State private var pendingDeleteOffsets: IndexSet?
    @State private var showDeleteModelConfirm = false
    
    var body: some View {
        List {
            if isEditingModels {
                ForEach($provider.models) { $model in
                    NavigationLink {
                        ModelSettingsView(model: $model)
                    } label: {
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
        .overlay {
            if isFetchingModels {
                progressOverlay
            }
        }
        .navigationTitle(provider.name)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    Task { await fetchAndMergeModels() }
                } label: {
                    Image(systemName: "icloud.and.arrow.down")
                }
                .disabled(isFetchingModels)
                .accessibilityLabel("从云端获取")
                
                Button {
                    isEditingModels.toggle()
                } label: {
                    Image(systemName: isEditingModels ? "checkmark.circle" : "pencil")
                }
                .accessibilityLabel(isEditingModels ? "完成编辑" : "编辑信息")
                
                Button {
                    isAddingModel = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加模型")
            }
        }
        .sheet(isPresented: $isAddingModel) {
            NavigationStack {
                ModelAddView(provider: $provider)
            }
        }
        .onChange(of: provider) { _, _ in
            saveChanges()
        }
        .alert("获取模型失败", isPresented: $showErrorAlert) {
            Button("好的", role: .cancel) { }
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
            let existingNames = Set(provider.models.map { $0.modelName })
            for model in fetchedModels where !existingNames.contains(model.modelName) {
                provider.models.append(model)
            }
        } catch {
            fetchError = error.localizedDescription
            showErrorAlert = true
        }
    }
    
    private func saveChanges() {
        var providerToSave = provider
        providerToSave.models = provider.models.filter { $0.isActivated }
        ConfigLoader.saveProvider(providerToSave)
        ChatService.shared.reloadProviders()
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
            return String(
                format: NSLocalizedString("确认删除以下模型：%@。", comment: ""),
                names.joined(separator: NSLocalizedString("、", comment: ""))
            )
        }
    }
    
    @ViewBuilder
    private var progressOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            ProgressView("正在获取…")
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct ModelAddView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var provider: Provider
    @State private var modelName: String = ""
    @State private var displayName: String = ""
    
    var body: some View {
        Form {
            Section("新模型信息") {
                TextField("模型ID", text: $modelName)
                TextField("模型名称", text: $displayName)
            }
        }
        .navigationTitle("添加模型")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("添加") {
                    addModel()
                }
                .disabled(modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
