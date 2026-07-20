// ============================================================================
// ProviderListView.swift
// ============================================================================
// ProviderListView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

import SwiftUI
import ETOSCore

struct ProviderListView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        List {
            Section(NSLocalizedString("管理入口", comment: "")) {
                NavigationLink {
                    WatchProviderManagementContentView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("提供商管理", comment: ""), systemImage: "shippingbox")
                }

                NavigationLink {
                    WatchProviderModelOrderContentView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("模型顺序", comment: ""), systemImage: "arrow.up.arrow.down")
                }

                NavigationLink {
                    SpecializedModelSelectorView()
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("专用模型", comment: ""), systemImage: "slider.horizontal.3")
                }

                NavigationLink {
                    GlobalProxySettingsView()
                } label: {
                    Label(NSLocalizedString("全局代理设置", comment: ""), systemImage: "network")
                }
            }
        }
        .navigationTitle(NSLocalizedString("提供商与模型管理", comment: ""))
    }
}

private struct WatchProviderManagementContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var isAddingProvider = false

    var body: some View {
        List {
            ForEach(providersBinding, id: \.id, editActions: .move) { $provider in
                NavigationLink {
                    ProviderActionsView(provider: provider)
                        .environmentObject(viewModel)
                } label: {
                    MarqueeTitleSubtitleLabel(
                        title: provider.name,
                        subtitle: provider.baseURL,
                        titleUIFont: .preferredFont(forTextStyle: .body),
                        subtitleUIFont: .preferredFont(forTextStyle: .caption2),
                        spacing: 2
                    )
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        deleteProvider(provider)
                    } label: {
                        Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("提供商管理", comment: ""))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { isAddingProvider = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingProvider) {
            NavigationStack {
                ProviderEditView(
                    provider: Provider(name: "", baseURL: "", apiKeys: [""], apiFormat: "openai-compatible"),
                    isNew: true
                )
                .environmentObject(viewModel)
            }
        }
    }

    private func deleteProvider(_ provider: Provider) {
        ChatService.shared.deleteProvider(provider)
    }

    private var providersBinding: Binding<[Provider]> {
        Binding {
            viewModel.providers
        } set: { orderedProviders in
            ChatService.shared.setProviderOrder(orderedProviders.map(\.id))
        }
    }
}

private struct WatchProviderModelOrderContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var appConfig = AppConfigStore.shared

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("模型选择方式", comment: "")),
                footer: Text(NSLocalizedString("经典列表会直接显示全部模型；按提供商会先选择提供商，再显示对应模型。", comment: ""))
            ) {
                Picker(
                    NSLocalizedString("模型选择方式", comment: ""),
                    selection: modelPickerGroupingBinding
                ) {
                    Text(NSLocalizedString("经典列表", comment: ""))
                        .tag(false)
                    Text(NSLocalizedString("按提供商", comment: ""))
                        .tag(true)
                }
            }

            Section(
                header: Text(NSLocalizedString("提供商顺序", comment: "")),
                footer: Text(NSLocalizedString("拖拽右侧把手调整提供商顺序；轻点提供商可调整其模型顺序。", comment: ""))
            ) {
                if viewModel.providers.isEmpty {
                    Text(NSLocalizedString("暂无提供商。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(providersBinding, id: \.id, editActions: .move) { $provider in
                        NavigationLink {
                            WatchProviderModelOrderDetailView(provider: provider)
                                .environmentObject(viewModel)
                        } label: {
                            MarqueeTitleSubtitleLabel(
                                title: provider.name,
                                subtitle: provider.baseURL,
                                titleUIFont: .preferredFont(forTextStyle: .body),
                                subtitleUIFont: .preferredFont(forTextStyle: .caption2),
                                spacing: 2
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("模型顺序", comment: ""))
    }

    private var modelPickerGroupingBinding: Binding<Bool> {
        Binding {
            appConfig.watchModelPickerGroupsByProvider
        } set: { groupsByProvider in
            appConfig.watchModelPickerGroupsByProvider = groupsByProvider
        }
    }

    private var providersBinding: Binding<[Provider]> {
        Binding {
            viewModel.providers
        } set: { orderedProviders in
            ChatService.shared.setProviderOrder(orderedProviders.map(\.id))
        }
    }
}

private struct ModelOrganizationBoundaryRow: Identifiable, Hashable {
    let item: RunnableModelPickerOrganization.BoundaryItem
    let depth: Int

    var id: String { item.id }
}

private struct WatchProviderModelOrderDetailView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var editingOrganization: RunnableModelPickerOrganization?
    @State private var boundaryRows: [ModelOrganizationBoundaryRow] = []
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    let provider: Provider

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("模型顺序", comment: "")),
                footer: Text(NSLocalizedString(
                    "拖动模型或文件夹边界调整位置。两个边界之间的模型属于该文件夹，边界可以嵌套但不能交叉。",
                    comment: "手表模型目录边界排序提示"
                ))
            ) {
                if boundaryRows.isEmpty {
                    Text(NSLocalizedString("暂无可排序模型。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(boundaryRows) { row in
                        boundaryRowContent(row)
                            .contentShape(Rectangle())
                            .accessibilityAction(named: Text(NSLocalizedString("上移", comment: ""))) {
                                moveBoundaryItem(row.id, by: -1)
                            }
                            .accessibilityAction(named: Text(NSLocalizedString("下移", comment: ""))) {
                                moveBoundaryItem(row.id, by: 1)
                            }
                    }
                    .onMove(perform: moveBoundaryRows)
                }
            }
        }
        .navigationTitle(provider.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let current = editingOrganization ?? organization
                    newFolderName = suggestedFolderName(organization: current)
                    isCreatingFolder = true
                } label: {
                    Label(NSLocalizedString("新建文件夹", comment: ""), systemImage: "folder.badge.plus")
                }
            }
        }
        .alert(NSLocalizedString("新建文件夹", comment: ""), isPresented: $isCreatingFolder) {
            TextField(NSLocalizedString("文件夹名称", comment: ""), text: $newFolderName)
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
            Button(NSLocalizedString("创建", comment: "")) {
                createFolder(named: newFolderName)
            }
            .disabled(normalizedGroupPath(newFolderName) == nil)
        }
        .onAppear {
            synchronize(with: organization)
        }
        .onChange(of: organization) { _, updated in
            synchronize(with: updated)
        }
    }

    private var organization: RunnableModelPickerOrganization {
        viewModel.configuredModelOrganizationsByProviderID[provider.id]
            ?? RunnableModelPickerOrganization(models: [])
    }

    @ViewBuilder
    private func boundaryRowContent(_ row: ModelOrganizationBoundaryRow) -> some View {
        switch row.item {
        case .model(let modelID):
            if let runnable = viewModel.configuredModelsByID[modelID] {
                HStack(alignment: .center, spacing: 6) {
                    if row.depth > 0 {
                        Image(systemName: "arrow.turn.down.right")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }

                    MarqueeTitleSubtitleLabel(
                        title: runnable.model.displayName,
                        subtitle: runnable.model.modelName,
                        titleUIFont: .preferredFont(forTextStyle: .body),
                        subtitleUIFont: .monospacedSystemFont(
                            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                            weight: .regular
                        ),
                        spacing: 2
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !runnable.model.isActivated {
                        Text(NSLocalizedString("未启用", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, CGFloat(row.depth) * 8)
            }

        case .groupStart(let groupPath):
            folderBoundaryRow(
                groupPath: groupPath,
                depth: row.depth,
                isStart: true
            )

        case .groupEnd(let groupPath):
            folderBoundaryRow(
                groupPath: groupPath,
                depth: row.depth,
                isStart: false
            )
        }
    }

    private func folderBoundaryRow(
        groupPath: String,
        depth: Int,
        isStart: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !isStart {
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(height: 2)
            }

            HStack(spacing: 4) {
                Image(systemName: isStart ? "folder.fill" : "folder")
                    .foregroundStyle(Color.accentColor)

                Text(groupPath.split(separator: "/").last.map(String.init) ?? groupPath)
                    .etFont(.caption)
                    .lineLimit(1)

                Spacer(minLength: 2)

                Text(NSLocalizedString(isStart ? "开始" : "结束", comment: "文件夹边界"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if isStart {
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(height: 2)
            }
        }
        .padding(.leading, CGFloat(depth) * 8)
        .accessibilityLabel(String(
            format: NSLocalizedString(
                isStart ? "文件夹“%@”开始" : "文件夹“%@”结束",
                comment: "模型目录边界辅助功能标签"
            ),
            groupPath.split(separator: "/").last.map(String.init) ?? groupPath
        ))
    }

    private func moveBoundaryRows(
        from source: IndexSet,
        to destination: Int
    ) {
        guard let editingOrganization else { return }
        var candidateItems = boundaryRows.map(\.item)
        candidateItems.move(fromOffsets: source, toOffset: destination)
        guard let updated = editingOrganization.applyingBoundaryItems(candidateItems) else {
            return
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
            self.editingOrganization = updated
            boundaryRows = Self.makeBoundaryRows(candidateItems)
        }
        persist(updated)
    }

    private func moveBoundaryItem(_ itemID: String, by offset: Int) {
        guard let editingOrganization,
              let sourceIndex = boundaryRows.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        let targetIndex = sourceIndex + offset
        guard boundaryRows.indices.contains(targetIndex) else { return }

        var candidateItems = boundaryRows.map(\.item)
        let movedItem = candidateItems.remove(at: sourceIndex)
        candidateItems.insert(movedItem, at: targetIndex)
        guard let updated = editingOrganization.applyingBoundaryItems(candidateItems) else {
            return
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
            self.editingOrganization = updated
            boundaryRows = Self.makeBoundaryRows(candidateItems)
        }
        persist(updated)
    }

    private func synchronize(with organization: RunnableModelPickerOrganization) {
        editingOrganization = organization
        boundaryRows = Self.makeBoundaryRows(organization.boundaryItems)
    }

    private static func makeBoundaryRows(
        _ items: [RunnableModelPickerOrganization.BoundaryItem]
    ) -> [ModelOrganizationBoundaryRow] {
        var depth = 0
        return items.map { item in
            switch item {
            case .model:
                return ModelOrganizationBoundaryRow(item: item, depth: depth)
            case .groupStart:
                defer { depth += 1 }
                return ModelOrganizationBoundaryRow(item: item, depth: depth)
            case .groupEnd:
                depth = max(0, depth - 1)
                return ModelOrganizationBoundaryRow(item: item, depth: depth)
            }
        }
    }

    private func createFolder(named name: String) {
        guard let groupPath = normalizedGroupPath(name) else { return }
        var updated = editingOrganization ?? organization
        guard !updated.allGroupPaths.contains(groupPath) else { return }

        updated.createGroup(groupPath)
        synchronize(with: updated)
        persist(updated)
    }

    private func suggestedFolderName(
        organization: RunnableModelPickerOrganization
    ) -> String {
        let baseName = NSLocalizedString("新建文件夹", comment: "")
        var suffix = 1
        while true {
            let folderName = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            if !organization.allGroupPaths.contains(folderName) {
                return folderName
            }
            suffix += 1
        }
    }

    private func normalizedGroupPath(_ path: String) -> String? {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    private func persist(_ updated: RunnableModelPickerOrganization) {
        ChatService.shared.setModelPickerOrganization(
            updated,
            for: provider.id
        )
    }
}
