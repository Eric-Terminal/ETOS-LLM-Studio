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
    @State private var editMode: EditMode = .inactive
    @AppStorage("providerDetail.groupByMainstream") private var groupByFamilySection = true

    var body: some View {
        List {
            Section("列表设置") {
                Toggle("按模型家族分组", isOn: $groupByFamilySection)
                if groupByFamilySection {
                    Text("已开启家族分组，关闭后可调整已添加模型排序。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if isSearching {
                    Text("搜索中暂不支持排序，请清空关键词后调整。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
        .environment(\.editMode, $editMode)
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
            ToolbarItem(placement: .navigationBarLeading) {
                if canShowReorderControl {
                    EditButton()
                        .accessibilityLabel(editMode.isEditing ? "完成排序" : "调整排序")
                }
            }

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
            if !canShowReorderControl {
                editMode = .inactive
            }
            saveChanges()
        }
        .onChange(of: groupByFamilySection) { _, isEnabled in
            if isEnabled {
                editMode = .inactive
            }
        }
        .onChange(of: searchText) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                editMode = .inactive
            }
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

    private func moveActiveModels(at offsets: IndexSet, to destination: Int, in indices: [Int]) {
        guard canReorderActiveModels else { return }
        let expectedActiveIndices = provider.models.indices.filter { provider.models[$0].isActivated }
        guard indices == expectedActiveIndices else { return }
        provider.moveActivatedModels(fromOffsets: offsets, toOffset: destination)
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
                .onMove { offsets, destination in
                    moveActiveModels(at: offsets, to: destination, in: indices)
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
            Text(model.modelName)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
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
