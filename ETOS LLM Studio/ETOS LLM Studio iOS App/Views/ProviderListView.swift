// ============================================================================
// ProviderListView.swift
// ============================================================================
// ProviderListView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import UniformTypeIdentifiers
import ETOSCore

private enum ProviderManagementTab: String, CaseIterable, Identifiable {
    case provider
    case modelOrder
    case specializedModel
    case globalProxy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .provider:
            return NSLocalizedString("提供商管理", comment: "")
        case .modelOrder:
            return NSLocalizedString("模型顺序", comment: "")
        case .specializedModel:
            return NSLocalizedString("专用模型", comment: "")
        case .globalProxy:
            return NSLocalizedString("全局代理", comment: "")
        }
    }

    var iconName: String {
        switch self {
        case .provider:
            return "shippingbox"
        case .modelOrder:
            return "arrow.up.arrow.down"
        case .specializedModel:
            return "slider.horizontal.3"
        case .globalProxy:
            return "network"
        }
    }
}

private enum ProviderConfigurationTab: String, CaseIterable, Identifiable {
    case models
    case provider

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models:
            return NSLocalizedString("模型配置", comment: "")
        case .provider:
            return NSLocalizedString("提供商配置", comment: "")
        }
    }

    var iconName: String {
        switch self {
        case .models:
            return "square.stack.3d.up"
        case .provider:
            return "slider.horizontal.3"
        }
    }
}

struct ProviderListView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var selectedTab: ProviderManagementTab = .provider
    @State private var isAddingProvider = false
    @State private var modelOrderEditMode: EditMode = .inactive

    var body: some View {
        TabView(selection: $selectedTab) {
            ProviderManagementContentView()
                .environmentObject(viewModel)
                .tabItem {
                    Label(ProviderManagementTab.provider.title, systemImage: ProviderManagementTab.provider.iconName)
                }
                .tag(ProviderManagementTab.provider)

            ProviderModelOrderContentView(editMode: $modelOrderEditMode)
                .environmentObject(viewModel)
                .tabItem {
                    Label(ProviderManagementTab.modelOrder.title, systemImage: ProviderManagementTab.modelOrder.iconName)
                }
                .tag(ProviderManagementTab.modelOrder)

            SpecializedModelSelectorView()
                .environmentObject(viewModel)
                .tabItem {
                    Label(ProviderManagementTab.specializedModel.title, systemImage: ProviderManagementTab.specializedModel.iconName)
                }
                .tag(ProviderManagementTab.specializedModel)

            GlobalProxySettingsView()
                .tabItem {
                    Label(ProviderManagementTab.globalProxy.title, systemImage: ProviderManagementTab.globalProxy.iconName)
                }
                .tag(ProviderManagementTab.globalProxy)
        }
        .navigationTitle(NSLocalizedString("提供商与模型管理", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if selectedTab == .provider {
                    Button {
                        isAddingProvider = true
                    } label: {
                        Label(NSLocalizedString("添加提供商", comment: ""), systemImage: "plus")
                    }
                } else if selectedTab == .modelOrder {
                    EditButton()
                        .environment(\.editMode, $modelOrderEditMode)
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
}

private struct ProviderManagementContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var providerToDelete: Provider?
    @State private var showDeleteAlert = false

    var body: some View {
        List {
            Section {
                ForEach(providersBinding, id: \.id, editActions: .move) { $provider in
                    NavigationLink {
                        ProviderConfigurationTabsView(provider: provider)
                            .environmentObject(viewModel)
                    } label: {
                        MarqueeTitleSubtitleLabel(
                            title: provider.name,
                            subtitle: provider.baseURL,
                            titleUIFont: .preferredFont(forTextStyle: .body),
                            subtitleUIFont: .preferredFont(forTextStyle: .caption1)
                        )
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            providerToDelete = provider
                            showDeleteAlert = true
                        } label: {
                            Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .alert(NSLocalizedString("确认删除提供商", comment: ""), isPresented: $showDeleteAlert) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let target = providerToDelete {
                    ChatService.shared.deleteProvider(target)
                }
                providerToDelete = nil
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                providerToDelete = nil
            }
        } message: {
            if let target = providerToDelete {
                if LocalModelProviderBridge.isLocalProvider(target) {
                    Text(NSLocalizedString("本地权重文件会保留；稍后重新开启本地模型时会自动恢复这个提供商。", comment: "Local provider delete disables feature message"))
                } else {
                    Text(String(format: NSLocalizedString("删除“%@”后无法恢复。", comment: ""), target.name))
                }
            } else {
                Text(NSLocalizedString("此操作无法撤销。", comment: ""))
            }
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

private struct ProviderConfigurationTabsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var provider: Provider
    @State private var selectedTab: ProviderConfigurationTab = .models
    @State private var providerRevision = 0
    @State private var addModelRequest = 0
    @State private var fetchModelsRequest = 0
    @State private var saveProviderRequest = 0
    @State private var canSaveProviderConfiguration = false
    @State private var hasUnsavedProviderConfiguration = false
    @State private var showUnsavedProviderAlert = false
    @State private var dismissAfterProviderSave = false
    @State private var isShowingModelTest = false

    init(provider: Provider) {
        _provider = State(initialValue: provider)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
                ProviderDetailView(
                    provider: provider,
                    showsToolbar: false,
                    addModelRequest: addModelRequest,
                    fetchModelsRequest: fetchModelsRequest,
                    allowsRemoteModelFetch: allowsRemoteModelFetch,
                    allowsModelTesting: allowsModelTesting,
                    allowsManualModelAdd: allowsManualModelAdd
                ) { updatedProvider in
                    updateProvider(updatedProvider)
                }
                .environmentObject(viewModel)
                .tabItem {
                    Label(ProviderConfigurationTab.models.title, systemImage: ProviderConfigurationTab.models.iconName)
                }
                .tag(ProviderConfigurationTab.models)

            ProviderEditView(
                provider: provider,
                isNew: false,
                dismissAfterSave: false,
                showsCancelButton: false,
                navigationTitleOverride: NSLocalizedString("提供商配置", comment: ""),
                saveRequest: saveProviderRequest,
                showsToolbarSaveButton: false,
                onSaveAvailabilityChange: { canSave in
                    canSaveProviderConfiguration = canSave
                    if !canSave {
                        dismissAfterProviderSave = false
                    }
                },
                onUnsavedChangesChange: { hasUnsavedProviderConfiguration = $0 }
            ) { updatedProvider in
                updateProvider(updatedProvider)
            }
            .id(providerRevision)
            .environmentObject(viewModel)
            .tabItem {
                Label(ProviderConfigurationTab.provider.title, systemImage: ProviderConfigurationTab.provider.iconName)
            }
            .tag(ProviderConfigurationTab.provider)
        }
        .navigationTitle(provider.name)
        .navigationBarBackButtonHidden(hasUnsavedProviderConfiguration)
        .toolbar {
            if hasUnsavedProviderConfiguration {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showUnsavedProviderAlert = true
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel(NSLocalizedString("返回", comment: ""))
                }
            }
            if selectedTab == .models {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        isShowingModelTest = true
                    } label: {
                        Image(systemName: "checkmark.seal")
                    }
                    .accessibilityLabel(NSLocalizedString("模型测试", comment: "Model connectivity test button"))
                    .disabled(!allowsModelTesting)

                    if allowsRemoteModelFetch {
                        Button {
                            fetchModelsRequest += 1
                        } label: {
                            Image(systemName: "icloud.and.arrow.down")
                        }
                        .accessibilityLabel(NSLocalizedString("从云端获取", comment: ""))
                    }

                    Button {
                        addModelRequest += 1
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(NSLocalizedString("添加模型", comment: ""))
                    .disabled(!allowsManualModelAdd)
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) {
                        dismissAfterProviderSave = true
                        saveProviderRequest += 1
                    }
                    .disabled(!canSaveProviderConfiguration)
                }
            }
        }
        .alert(NSLocalizedString("未保存更改", comment: "Unsaved changes alert title"), isPresented: $showUnsavedProviderAlert) {
            if canSaveProviderConfiguration {
                Button(NSLocalizedString("保存并离开", comment: "Save and leave button")) {
                    dismissAfterProviderSave = true
                    saveProviderRequest += 1
                }
            }
            Button(NSLocalizedString("放弃更改", comment: "Discard changes button"), role: .destructive) {
                dismiss()
            }
            Button(NSLocalizedString("继续编辑", comment: "Continue editing button"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("要保存当前编辑内容，还是放弃更改并离开？", comment: "Generic unsaved changes alert message"))
        }
        .sheet(isPresented: $isShowingModelTest) {
            NavigationStack {
                ModelConnectivityTestView(provider: provider)
            }
        }
    }

    private var allowsRemoteModelFetch: Bool {
        !LocalModelProviderBridge.isLocalProvider(provider) && provider.apiFormat.lowercased() != "anthropic"
    }

    private var allowsModelTesting: Bool {
        !LocalModelProviderBridge.isLocalProvider(provider)
    }

    private var allowsManualModelAdd: Bool {
        !LocalModelProviderBridge.isLocalProvider(provider)
    }

    private func updateProvider(_ updatedProvider: Provider) {
        guard provider != updatedProvider else {
            hasUnsavedProviderConfiguration = false
            if dismissAfterProviderSave {
                dismissAfterProviderSave = false
                dismiss()
            }
            return
        }
        provider = updatedProvider
        hasUnsavedProviderConfiguration = false
        providerRevision += 1
        if dismissAfterProviderSave {
            dismissAfterProviderSave = false
            dismiss()
        }
    }
}

private struct ProviderModelOrderContentView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var appConfig = AppConfigStore.shared
    @Binding var editMode: EditMode

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
                .pickerStyle(.segmented)
                .labelsHidden()
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
                            ProviderModelOrderDetailView(provider: provider)
                                .environmentObject(viewModel)
                        } label: {
                            MarqueeTitleSubtitleLabel(
                                title: provider.name,
                                subtitle: provider.baseURL,
                                titleUIFont: .preferredFont(forTextStyle: .body),
                                subtitleUIFont: .preferredFont(forTextStyle: .caption1)
                            )
                        }
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
    }

    private var modelPickerGroupingBinding: Binding<Bool> {
        Binding {
            appConfig.iOSModelPickerGroupsByProvider
        } set: { groupsByProvider in
            appConfig.iOSModelPickerGroupsByProvider = groupsByProvider
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

private struct ModelOrganizationBoundaryDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggingItemID: String?
    let moveItem: (String, String) -> Void
    let finishMove: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingItemID != nil
    }

    func dropEntered(info: DropInfo) {
        guard let draggingItemID, draggingItemID != targetID else { return }
        moveItem(draggingItemID, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard draggingItemID != nil else { return false }
        finishMove()
        draggingItemID = nil
        return true
    }
}

private struct ProviderModelOrderDetailView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var editingOrganization: RunnableModelPickerOrganization?
    @State private var boundaryRows: [ModelOrganizationBoundaryRow] = []
    @State private var draggingItemID: String?
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    let provider: Provider

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("模型顺序", comment: "")),
                footer: Text(NSLocalizedString(
                    "长按并拖动模型或文件夹边界调整位置。两个边界之间的模型属于该文件夹，边界可以嵌套但不能交叉。",
                    comment: "模型目录边界排序提示"
                ))
            ) {
                if boundaryRows.isEmpty {
                    Text(NSLocalizedString("暂无可排序模型。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(boundaryRows) { row in
                        draggableBoundaryRow(row)
                    }
                }
            }
        }
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
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
            guard draggingItemID == nil else { return }
            synchronize(with: updated)
        }
    }

    private var organization: RunnableModelPickerOrganization {
        viewModel.configuredModelOrganizationsByProviderID[provider.id]
            ?? RunnableModelPickerOrganization(models: [])
    }

    private func draggableBoundaryRow(
        _ row: ModelOrganizationBoundaryRow
    ) -> some View {
        boundaryRowContent(row)
            .contentShape(Rectangle())
            .onDrag {
                draggingItemID = row.id
                return NSItemProvider(object: row.id as NSString)
            }
            .onDrop(
                of: [.plainText],
                delegate: ModelOrganizationBoundaryDropDelegate(
                    targetID: row.id,
                    draggingItemID: $draggingItemID,
                    moveItem: moveBoundaryItem,
                    finishMove: commitBoundaryOrder
                )
            )
            .accessibilityAction(named: Text(NSLocalizedString("上移", comment: ""))) {
                moveBoundaryItem(row.id, by: -1)
            }
            .accessibilityAction(named: Text(NSLocalizedString("下移", comment: ""))) {
                moveBoundaryItem(row.id, by: 1)
            }
    }

    @ViewBuilder
    private func boundaryRowContent(_ row: ModelOrganizationBoundaryRow) -> some View {
        switch row.item {
        case .model(let modelID):
            if let runnable = viewModel.configuredModelsByID[modelID] {
                HStack(alignment: .center) {
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
                        )
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !runnable.model.isActivated {
                        Text(NSLocalizedString("未启用", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, CGFloat(row.depth) * 14)
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
        VStack(alignment: .leading, spacing: 6) {
            if !isStart {
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(height: 2)
            }

            HStack {
                Image(systemName: isStart ? "folder.fill" : "folder")
                    .foregroundStyle(Color.accentColor)

                Text(groupPath.split(separator: "/").last.map(String.init) ?? groupPath)
                    .etFont(.headline)
                    .lineLimit(1)

                Spacer()

                Text(NSLocalizedString(isStart ? "开始" : "结束", comment: "文件夹边界"))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }

            if isStart {
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(height: 2)
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .listRowSeparator(.hidden)
        .accessibilityLabel(String(
            format: NSLocalizedString(
                isStart ? "文件夹“%@”开始" : "文件夹“%@”结束",
                comment: "模型目录边界辅助功能标签"
            ),
            groupPath.split(separator: "/").last.map(String.init) ?? groupPath
        ))
    }

    private func moveBoundaryItem(_ itemID: String, over targetID: String) {
        guard itemID != targetID,
              let editingOrganization,
              let sourceIndex = boundaryRows.firstIndex(where: { $0.id == itemID }),
              let targetIndex = boundaryRows.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        var candidateItems = boundaryRows.map(\.item)
        let movedItem = candidateItems.remove(at: sourceIndex)
        guard let adjustedTargetIndex = candidateItems.firstIndex(where: {
            $0.id == targetID
        }) else {
            return
        }
        let insertionIndex: Int
        switch (movedItem, candidateItems[adjustedTargetIndex]) {
        case (.model, .groupStart):
            insertionIndex = adjustedTargetIndex + 1
        case (.model, .groupEnd):
            insertionIndex = adjustedTargetIndex
        default:
            insertionIndex = sourceIndex < targetIndex
                ? adjustedTargetIndex + 1
                : adjustedTargetIndex
        }
        candidateItems.insert(movedItem, at: insertionIndex)
        guard editingOrganization.applyingBoundaryItems(candidateItems) != nil else {
            return
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
            boundaryRows = Self.makeBoundaryRows(candidateItems)
        }
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

    private func commitBoundaryOrder() {
        guard let editingOrganization,
              let updated = editingOrganization.applyingBoundaryItems(
                boundaryRows.map(\.item)
              ) else {
            synchronize(with: editingOrganization ?? organization)
            return
        }

        self.editingOrganization = updated
        boundaryRows = Self.makeBoundaryRows(updated.boundaryItems)
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
