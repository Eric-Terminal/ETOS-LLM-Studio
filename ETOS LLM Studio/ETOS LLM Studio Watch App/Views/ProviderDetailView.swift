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
    @State private var isSortModeEnabled = false
    @FocusState private var isSearchFieldFocused: Bool
    @AppStorage("providerDetail.groupByMainstream") private var groupByFamilySection = true
    
    var body: some View {
        ZStack {
            List {
                if isSearchPresented {
                    Section {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("输入关键词", text: $searchText.watchKeyboardNewlineBinding())
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

                Section("列表设置") {
                    Toggle("按模型家族分组", isOn: $groupByFamilySection)
                    if groupByFamilySection {
                        Text("已开启家族分组，关闭后可调整已添加模型排序。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else if isSearching {
                        Text("搜索中暂不支持排序，请清空关键词后调整。")
                            .font(.footnote)
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
                        title: "已添加",
                        indices: filteredIndices(forActive: true),
                        isActive: true
                    )
                    modelSection(
                        title: "未添加",
                        indices: filteredIndices(forActive: false),
                        isActive: false
                    )
                }
            }
            .id(groupByFamilySection ? "family-grouped" : "flat-grouped")
            
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
                    Button(action: { toggleSearch() }) {
                        Image(systemName: isSearchPresented ? "xmark" : "magnifyingglass")
                    }
                    .accessibilityLabel(isSearchPresented ? "取消搜索" : "搜索模型")
                    if canShowReorderControl {
                        Spacer()
                        Button(action: { toggleSortMode() }) {
                            Image(systemName: isSortModeEnabled ? "checkmark" : "arrow.up.arrow.down")
                        }
                        .accessibilityLabel(isSortModeEnabled ? "完成排序" : "调整排序")
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingModel) {
            ModelAddView(provider: $provider)
        }
        .onChange(of: provider) {
            if !canShowReorderControl {
                isSortModeEnabled = false
            }
            saveChanges()
        }
        .onChange(of: groupByFamilySection) { _, isEnabled in
            if isEnabled {
                isSortModeEnabled = false
            }
        }
        .onChange(of: searchText) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isSortModeEnabled = false
            }
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

    private func moveActiveModelUp(at position: Int) {
        guard canReorderActiveModels else { return }
        guard position > 0 else { return }
        provider.moveActivatedModel(fromPosition: position, toPosition: position - 1)
    }

    private func moveActiveModelDown(at position: Int, total: Int) {
        guard canReorderActiveModels else { return }
        guard position >= 0 && position + 1 < total else { return }
        provider.moveActivatedModel(fromPosition: position, toPosition: position + 1)
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

    private var activeModelCount: Int {
        provider.models.reduce(into: 0) { count, model in
            if model.isActivated {
                count += 1
            }
        }
    }

    private var canReorderActiveModels: Bool {
        !groupByFamilySection && !isSearching
    }

    private var canShowReorderControl: Bool {
        canReorderActiveModels && activeModelCount > 1
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
        let sectionPrefix = isActive ? "已添加" : "未添加"

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
                    title: "\(sectionPrefix) · \(family.displayName)",
                    indices: familyIndices,
                    isActive: isActive
                )
            )
        }

        if !otherIndices.isEmpty {
            result.append(
                ModelListSection(
                    title: "\(sectionPrefix) · 其他",
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
            return isActive ? "没有匹配的已添加模型" : "没有匹配的未添加模型"
        }
        return isActive ? "暂无已添加模型" : "暂无未添加模型"
    }

    @ViewBuilder
    private func modelSection(title: String, indices: [Int], isActive: Bool) -> some View {
        Section(title) {
            if indices.isEmpty {
                Text(emptyStateText(forActiveSection: isActive))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else if isActive {
                ForEach(Array(indices.enumerated()), id: \.element) { position, index in
                    modelRow(
                        for: index,
                        isActive: true,
                        activePosition: position,
                        activeCount: indices.count
                    )
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
            isSortModeEnabled = false
            isSearchPresented = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isSearchFieldFocused = true
            }
        }
    }

    private func toggleSortMode() {
        guard canShowReorderControl else { return }
        isSortModeEnabled.toggle()
    }

    @ViewBuilder
    private func modelRow(
        for index: Int,
        isActive: Bool,
        activePosition: Int? = nil,
        activeCount: Int = 0
    ) -> some View {
        let model = provider.models[index]

        if isActive {
            if isSortModeEnabled && canReorderActiveModels, let activePosition {
                HStack(spacing: 6) {
                    modelLabel(for: model)
                    Spacer()
                    VStack(spacing: 4) {
                        Button {
                            moveActiveModelUp(at: activePosition)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(activePosition == 0)
                        .accessibilityLabel("上移模型")

                        Button {
                            moveActiveModelDown(at: activePosition, total: activeCount)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(activePosition + 1 >= activeCount)
                        .accessibilityLabel("下移模型")
                    }
                }
            } else {
                NavigationLink(destination: ModelSettingsView(model: $provider.models[index], provider: provider)) {
                    modelLabel(for: model)
                }
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
                .accessibilityLabel("激活模型")
            }
        }
    }

    private func modelLabel(for model: Model) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.displayName)
                .lineLimit(1)
            Text(model.modelName)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
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
                Section(header: Text("新模型信息")) {
                    TextField("模型ID (e.g., gpt-4o)", text: $modelName.watchKeyboardNewlineBinding())
                    TextField("模型名称 (可选)", text: $displayName.watchKeyboardNewlineBinding())
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
            displayName: displayName.isEmpty ? modelName : displayName,
            isActivated: true
        )
        provider.models.append(newModel)
        dismiss()
    }
}
