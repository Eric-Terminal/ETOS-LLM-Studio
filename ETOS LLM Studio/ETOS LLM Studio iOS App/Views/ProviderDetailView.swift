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
    @AppStorage("providerDetail.modelCategoryFilter") private var modelCategoryFilterRaw = ModelCategoryFilter.all.rawValue
    @AppStorage("providerDetail.groupByMainstream") private var groupByMainstreamCategory = true

    var body: some View {
        let groupedIndices = buildGroupedIndices()

        List {
            Section("列表设置") {
                Picker("模型分类", selection: modelCategoryFilterBinding) {
                    ForEach(ModelCategoryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("按主流/其他分组", isOn: $groupByMainstreamCategory)
            }

            if groupByMainstreamCategory {
                if modelCategoryFilter != .other {
                    modelSection(
                        title: "已添加 · 主流",
                        indices: groupedIndices.activeMainstream,
                        isActive: true
                    )
                }
                if modelCategoryFilter != .mainstream {
                    modelSection(
                        title: "已添加 · 其他",
                        indices: groupedIndices.activeOther,
                        isActive: true
                    )
                }
                if modelCategoryFilter != .other {
                    modelSection(
                        title: "未添加 · 主流",
                        indices: groupedIndices.inactiveMainstream,
                        isActive: false
                    )
                }
                if modelCategoryFilter != .mainstream {
                    modelSection(
                        title: "未添加 · 其他",
                        indices: groupedIndices.inactiveOther,
                        isActive: false
                    )
                }
            } else {
                modelSection(
                    title: "已添加",
                    indices: groupedIndices.filteredActive,
                    isActive: true
                )
                modelSection(
                    title: "未添加",
                    indices: groupedIndices.filteredInactive,
                    isActive: false
                )
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

    private func modelMatchesCategoryFilter(_ model: Model) -> Bool {
        switch modelCategoryFilter {
        case .all:
            return true
        case .mainstream:
            return model.isMainstreamModel
        case .other:
            return !model.isMainstreamModel
        }
    }

    private func buildGroupedIndices() -> GroupedModelIndices {
        var grouped = GroupedModelIndices()

        for index in provider.models.indices {
            let model = provider.models[index]
            guard modelMatchesSearch(model), modelMatchesCategoryFilter(model) else {
                continue
            }

            if model.isActivated {
                grouped.filteredActive.append(index)
            } else {
                grouped.filteredInactive.append(index)
            }

            if model.isMainstreamModel {
                if model.isActivated {
                    grouped.activeMainstream.append(index)
                } else {
                    grouped.inactiveMainstream.append(index)
                }
            } else {
                if model.isActivated {
                    grouped.activeOther.append(index)
                } else {
                    grouped.inactiveOther.append(index)
                }
            }
        }

        return grouped
    }

    private var modelCategoryFilter: ModelCategoryFilter {
        ModelCategoryFilter(rawValue: modelCategoryFilterRaw) ?? .all
    }

    private var modelCategoryFilterBinding: Binding<ModelCategoryFilter> {
        Binding(
            get: { modelCategoryFilter },
            set: { modelCategoryFilterRaw = $0.rawValue }
        )
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
    private func modelSection(title: String, indices: [Int], isActive: Bool) -> some View {
        Section(title) {
            if indices.isEmpty {
                Text(emptyStateText(forActiveSection: isActive))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if isActive {
                ForEach(indices, id: \.self) { index in
                    modelRow(for: index, isActive: true)
                }
                .onDelete { offsets in
                    deleteModels(at: offsets, in: indices)
                }
            } else {
                ForEach(indices, id: \.self) { index in
                    modelRow(for: index, isActive: false)
                }
            }
        }
    }

    private func emptyStateText(forActiveSection isActive: Bool) -> String {
        if isSearching {
            return isActive ? "没有匹配的已添加模型" : "没有匹配的未添加模型"
        }
        return isActive ? "暂无已添加模型" : "暂无未添加模型"
    }

    @ViewBuilder
    private func modelRow(for index: Int, isActive: Bool) -> some View {
        let model = provider.models[index]

        if isActive {
            NavigationLink {
                ModelSettingsView(model: $provider.models[index], provider: provider)
            } label: {
                modelLabel(for: model)
            }
        } else {
            HStack(spacing: 10) {
                modelLabel(for: model)
                Spacer()
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

    private func modelLabel(for model: Model) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.displayName)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(model.modelName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(model.mainstreamFamily?.displayName ?? "其他")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(model.isMainstreamModel ? .blue : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(
                                model.isMainstreamModel
                                ? Color.blue.opacity(0.12)
                                : Color.secondary.opacity(0.12)
                            )
                    )
            }
        }
    }
}

private struct GroupedModelIndices {
    var activeMainstream: [Int] = []
    var activeOther: [Int] = []
    var inactiveMainstream: [Int] = []
    var inactiveOther: [Int] = []
    var filteredActive: [Int] = []
    var filteredInactive: [Int] = []
}

private enum ModelCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case mainstream
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .mainstream:
            return "主流"
        case .other:
            return "其他"
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
