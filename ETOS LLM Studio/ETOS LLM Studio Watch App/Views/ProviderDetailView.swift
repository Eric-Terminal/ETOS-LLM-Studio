// ============================================================================
// ProviderDetailView.swift
// ============================================================================
// ETOS LLM Studio Watch App 提供商详情视图
//
// 定义内容:
// - 显示一个提供商下的所有模型
// - 允许用户激活/禁用模型、添加新模型、从云端获取模型列表
// - 支持按模型家族分组与筛选
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
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @FocusState private var isSearchFieldFocused: Bool
    @AppStorage("providerDetail.groupByMainstream") private var groupByFamilySection = true
    
    var body: some View {
        ZStack {
            List {
                Section(NSLocalizedString("提供商信息", comment: "")) {
                    MarqueeTitleSubtitleLabel(
                        title: provider.name,
                        subtitle: provider.baseURL,
                        titleUIFont: .preferredFont(forTextStyle: .body),
                        subtitleUIFont: .preferredFont(forTextStyle: .caption2),
                        spacing: 2
                    )
                }

                if isSearchPresented {
                    Section {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField(NSLocalizedString("输入关键词", comment: ""), text: $searchText.watchKeyboardNewlineBinding())
                                .focused($isSearchFieldFocused)
                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section(NSLocalizedString("列表设置", comment: "")) {
                    Toggle(NSLocalizedString("按模型家族分组", comment: ""), isOn: $groupByFamilySection)
                    if groupByFamilySection {
                        Text(NSLocalizedString("将按模型家族拆分显示。", comment: ""))
                            .etFont(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        Text(NSLocalizedString("将按已添加/未添加展示。", comment: ""))
                            .etFont(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                if groupByFamilySection {
                    let activeSections = sections(forActive: true)
                    let inactiveSections = sections(forActive: false)

                    ForEach(activeSections) { section in
                        modelSection(
                            title: section.title,
                            indices: section.indices,
                            isActive: section.isActive
                        )
                    }

                    ForEach(inactiveSections) { section in
                        modelSection(
                            title: section.title,
                            indices: section.indices,
                            isActive: section.isActive
                        )
                    }
                } else {
                    modelSection(
                        title: NSLocalizedString("已添加", comment: ""),
                        indices: filteredIndices(forActive: true),
                        isActive: true
                    )
                    modelSection(
                        title: NSLocalizedString("未添加", comment: ""),
                        indices: filteredIndices(forActive: false),
                        isActive: false
                    )
                }
            }
            .id(groupByFamilySection ? "family-grouped" : "flat-grouped")
            
            if isFetchingModels {
                ProgressView(NSLocalizedString("正在获取...", comment: ""))
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
                    Button(action: { toggleSearch() }) {
                        Image(systemName: isSearchPresented ? "xmark" : "magnifyingglass")
                    }
                    .accessibilityLabel(isSearchPresented ? NSLocalizedString("取消搜索", comment: "") : NSLocalizedString("搜索模型", comment: ""))
                }
            }
        }
        .sheet(isPresented: $isAddingModel) {
            ModelAddView(provider: $provider)
        }
        .onChange(of: provider) {
            saveChanges()
        }
        .alert(NSLocalizedString("获取模型失败", comment: ""), isPresented: $showErrorAlert) {
            Button(NSLocalizedString("好的", comment: "")) { }
        } message: {
            Text(fetchError ?? NSLocalizedString("发生未知错误。", comment: ""))
        }
    }
    
    private func fetchAndMergeModels() async {
        isFetchingModels = true
        defer { isFetchingModels = false }
        
        do {
            let fetchedModels = try await ChatService.shared.fetchModels(for: provider)
            let existingModelNames = Set(provider.models.map { $0.modelName })

            for fetchedModel in fetchedModels where !existingModelNames.contains(fetchedModel.modelName) {
                provider.models.append(fetchedModel)
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

    private func filteredIndices(forActive isActive: Bool) -> [Int] {
        provider.models.indices.filter { index in
            let model = provider.models[index]
            return model.isActivated == isActive
                && modelMatchesSearch(model)
        }
    }

    private func sections(forActive isActive: Bool) -> [ModelListSection] {
        let indices = filteredIndices(forActive: isActive)
        let sectionPrefix = isActive ? NSLocalizedString("已添加", comment: "") : NSLocalizedString("未添加", comment: "")

        guard groupByFamilySection else {
            return [ModelListSection(title: sectionPrefix, indices: indices, isActive: isActive)]
        }

        var indicesByFamily: [MainstreamModelFamily: [Int]] = [:]
        var otherIndices: [Int] = []
        for index in indices {
            if let family = provider.models[index].mainstreamFamily {
                indicesByFamily[family, default: []].append(index)
            } else {
                otherIndices.append(index)
            }
        }

        var result: [ModelListSection] = []
        for family in MainstreamModelFamily.allCases {
            guard let familyIndices = indicesByFamily[family], !familyIndices.isEmpty else { continue }
            result.append(
                ModelListSection(
                    title: String(format: NSLocalizedString("%@ · %@", comment: ""), sectionPrefix, family.displayName),
                    indices: familyIndices,
                    isActive: isActive
                )
            )
        }

        if !otherIndices.isEmpty {
            result.append(
                ModelListSection(
                    title: String(format: NSLocalizedString("%@ · %@", comment: ""), sectionPrefix, NSLocalizedString("其他", comment: "")),
                    indices: otherIndices,
                    isActive: isActive
                )
            )
        }

        if result.isEmpty {
            return [ModelListSection(title: sectionPrefix, indices: [], isActive: isActive)]
        }
        return result
    }

    private func emptyStateText(forActiveSection isActive: Bool) -> String {
        if isSearching {
            return isActive ? NSLocalizedString("没有匹配的已添加模型", comment: "") : NSLocalizedString("没有匹配的未添加模型", comment: "")
        }
        return isActive ? NSLocalizedString("暂无已添加模型", comment: "") : NSLocalizedString("暂无未添加模型", comment: "")
    }

    @ViewBuilder
    private func modelSection(title: String, indices: [Int], isActive: Bool) -> some View {
        Section(NSLocalizedString(title, comment: "模型列表分组标题")) {
            if indices.isEmpty {
                Text(emptyStateText(forActiveSection: isActive))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
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

    private func toggleSearch() {
        if isSearchPresented {
            isSearchPresented = false
            searchText = ""
            isSearchFieldFocused = false
        } else {
            isSearchPresented = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isSearchFieldFocused = true
            }
        }
    }

    @ViewBuilder
    private func modelRow(
        for index: Int,
        isActive: Bool
    ) -> some View {
        let model = provider.models[index]

        if isActive {
            NavigationLink(destination: ModelSettingsView(model: $provider.models[index], provider: provider)) {
                modelLabel(for: model)
            }
        } else {
            HStack(spacing: 6) {
                modelLabel(for: model)
                Spacer()
                Button {
                    provider.models[index].isActivated = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(NSLocalizedString("激活模型", comment: ""))
            }
        }
    }

    private func modelLabel(for model: Model) -> some View {
        MarqueeTitleSubtitleLabel(
            title: model.displayName,
            subtitle: model.modelName,
            titleUIFont: .preferredFont(forTextStyle: .body),
            subtitleUIFont: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                weight: .regular
            ),
            spacing: 2
        )
    }
}

private struct ModelListSection: Identifiable {
    let title: String
    let indices: [Int]
    let isActive: Bool

    var id: String {
        "\(isActive ? "active" : "inactive")-\(title)"
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
                Section(header: Text(NSLocalizedString("新模型信息", comment: ""))) {
                    TextField(NSLocalizedString("模型ID (e.g., gpt-4o)", comment: ""), text: $modelName.watchKeyboardNewlineBinding())
                    TextField(NSLocalizedString("模型名称 (可选)", comment: ""), text: $displayName.watchKeyboardNewlineBinding())
                }
                Section {
                    Button(NSLocalizedString("添加模型", comment: "")) {
                        addModel()
                    }
                    .disabled(modelName.isEmpty)
                }
            }
            .navigationTitle(NSLocalizedString("添加模型", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }
                }
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
