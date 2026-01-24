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

        List {
            Section("已添加") {
                if activeIndices.isEmpty {
                    Text("暂无已添加模型")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activeIndices, id: \.self) { index in
                        modelRow(for: index, isActive: true)
                    }
                    .onDelete { offsets in
                        deleteModels(at: offsets, in: activeIndices)
                    }
                }
            }

            Section("未添加") {
                if inactiveIndices.isEmpty {
                    Text("暂无未添加模型")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(inactiveIndices, id: \.self) { index in
                        modelRow(for: index, isActive: false)
                    }
                }
            }
        }
        .overlay {
            if isFetchingModels {
                progressOverlay
            }
        }
        .navigationTitle(provider.name)
        .task {
            guard !hasAutoFetchedModels, !isFetchingModels else { return }
            hasAutoFetchedModels = true
            await fetchAndMergeModels()
        }
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
    
    private func deleteModels(at offsets: IndexSet, in indices: [Int]) {
        let mappedOffsets = IndexSet(offsets.compactMap { offset in
            indices.indices.contains(offset) ? indices[offset] : nil
        })
        provider.models.remove(atOffsets: mappedOffsets)
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

    private func activeModelIndices() -> [Int] {
        provider.models.indices.filter { provider.models[$0].isActivated }
    }

    private func inactiveModelIndices() -> [Int] {
        provider.models.indices.filter { !provider.models[$0].isActivated }
    }

    @ViewBuilder
    private func modelRow(for index: Int, isActive: Bool) -> some View {
        if isActive {
            NavigationLink {
                ModelSettingsView(model: $provider.models[index], provider: provider)
            } label: {
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
            displayName: displayName.isEmpty ? modelName : displayName,
            isActivated: true
        )
        provider.models.append(newModel)
        dismiss()
    }
}
