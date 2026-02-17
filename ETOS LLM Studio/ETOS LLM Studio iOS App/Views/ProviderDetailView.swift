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
    @State private var searchText = ""
    
    var body: some View {
        let activeIndices = activeModelIndices()
        let inactiveIndices = inactiveModelIndices()

        List {
            Section("已添加") {
                if activeIndices.isEmpty {
                    Text(isSearching ? "没有匹配的已添加模型" : "暂无已添加模型")
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
                    Text(isSearching ? "没有匹配的未添加模型" : "暂无未添加模型")
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
        .safeAreaInset(edge: .top) {
            searchPill
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
        provider.models.indices.filter {
            provider.models[$0].isActivated && modelMatchesSearch(provider.models[$0])
        }
    }

    private func inactiveModelIndices() -> [Int] {
        provider.models.indices.filter {
            !provider.models[$0].isActivated && modelMatchesSearch(provider.models[$0])
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !normalizedSearchText.isEmpty
    }

    private func modelMatchesSearch(_ model: Model) -> Bool {
        guard isSearching else { return true }
        let keyword = normalizedSearchText.lowercased()
        return model.displayName.lowercased().contains(keyword)
            || model.modelName.lowercased().contains(keyword)
    }

    private var searchPill: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("搜索模型（名称或ID）", text: $searchText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索关键词")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.6)
        )
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
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
