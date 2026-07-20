// ============================================================================
// ProviderListView.swift
// ============================================================================
// ProviderListView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
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

private enum ModelOrganizationDragPayload {
    private static let modelPrefix = "model:"
    private static let groupPrefix = "group:"

    static func model(_ modelID: String) -> String {
        modelPrefix + modelID
    }

    static func group(_ groupName: String) -> String {
        groupPrefix + groupName
    }

    static func modelID(from payload: String) -> String? {
        guard payload.hasPrefix(modelPrefix) else { return nil }
        return String(payload.dropFirst(modelPrefix.count))
    }

    static func groupName(from payload: String) -> String? {
        guard payload.hasPrefix(groupPrefix) else { return nil }
        return String(payload.dropFirst(groupPrefix.count))
    }
}

private struct ModelOrganizationDestinationFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct ProviderModelOrderDetailView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var targetedDestinationID: String?
    @State private var draggedPayload: String?
    @State private var dragTranslation: CGSize = .zero
    @State private var destinationFrames: [String: CGRect] = [:]
    @State private var folderHoverTask: Task<Void, Never>?
    @State private var isFolderCreationReady = false
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    let provider: Provider

    private let dragCoordinateSpace = "ios-model-organization"

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("模型顺序", comment: "")),
                footer: Text(NSLocalizedString(
                    "长按条目直接拖动；拖到文件夹或根目录，两个模型重叠停留可组成文件夹。",
                    comment: "模型目录拖放操作提示"
                ))
            ) {
                if organization.rootItems.isEmpty {
                    Text(NSLocalizedString("暂无可排序模型。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    organizationRows(
                        organization.rootItems,
                        parentGroupPath: nil,
                        depth: 0
                    )

                    rootDropTarget
                }
            }
        }
        .coordinateSpace(name: dragCoordinateSpace)
        .onPreferenceChange(ModelOrganizationDestinationFramesKey.self) { frames in
            destinationFrames = frames
        }
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newFolderName = suggestedFolderName(in: nil, organization: organization)
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
    }

    private var organization: RunnableModelPickerOrganization {
        viewModel.configuredModelOrganizationsByProviderID[provider.id]
            ?? RunnableModelPickerOrganization(models: [])
    }

    private func organizationRows(
        _ items: [RunnableModelPickerOrganization.RootItem],
        parentGroupPath: String?,
        depth: Int
    ) -> AnyView {
        AnyView(
            ForEach(items) { item in
                switch item {
                case .model(let modelID):
                    if let model = viewModel.configuredModelsByID[modelID] {
                        draggableOrganizationRow(
                            modelOrderRow(model, depth: depth),
                            payload: ModelOrganizationDragPayload.model(modelID),
                            destinationID: item.id,
                            expandsFolders: true
                        )
                    }
                case .group(let groupPath, let children):
                    draggableOrganizationRow(
                        folderRow(
                            groupPath: groupPath,
                            modelCount: item.modelIDs.count,
                            depth: depth
                        ),
                        payload: ModelOrganizationDragPayload.group(groupPath),
                        destinationID: item.id,
                        expandsFolders: false
                    )

                    if isFolderExpanded(groupPath) {
                        organizationRows(
                            children,
                            parentGroupPath: groupPath,
                            depth: depth + 1
                        )
                    }
                }
            }
        )
    }

    private func folderRow(groupPath: String, modelCount: Int, depth: Int) -> some View {
        Button {
            let expansionID = folderExpansionID(groupPath)
            if appConfig.iOSModelPickerExpandedGroupIDs.contains(expansionID) {
                appConfig.iOSModelPickerExpandedGroupIDs.remove(expansionID)
            } else {
                appConfig.iOSModelPickerExpandedGroupIDs.insert(expansionID)
            }
        } label: {
            HStack {
                Label(
                    groupPath.split(separator: "/").last.map(String.init) ?? groupPath,
                    systemImage: isFolderExpanded(groupPath) ? "folder.fill" : "folder"
                )
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(modelCount)")
                    .etFont(.caption)
                    .foregroundStyle(.secondary)

                Image(systemName: isFolderExpanded(groupPath) ? "chevron.down" : "chevron.right")
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.leading, CGFloat(depth) * 14)
        }
        .buttonStyle(.plain)
    }

    private func modelOrderRow(_ runnable: RunnableModel, depth: Int) -> some View {
        HStack(alignment: .top) {
            if depth > 0 {
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
        .contentShape(Rectangle())
        .padding(.leading, CGFloat(depth) * 14)
    }

    private func draggableOrganizationRow<Content: View>(
        _ content: Content,
        payload: String,
        destinationID: String,
        expandsFolders: Bool
    ) -> some View {
        let isDragging = draggedPayload == payload
        let isFormingFolder = targetedDestinationID == destinationID && isFolderCreationReady
        return content
            .opacity(isDragging ? 0.82 : 1)
            .scaleEffect(isDragging ? 1.03 : (isFormingFolder ? 1.02 : 1))
            .background(dropHighlight(for: destinationID))
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ModelOrganizationDestinationFramesKey.self,
                        value: [destinationID: proxy.frame(in: .named(dragCoordinateSpace))]
                    )
                }
            }
            .offset(isDragging ? dragTranslation : .zero)
            .zIndex(isDragging ? 1 : 0)
            .shadow(
                color: .black.opacity(isDragging ? 0.16 : 0),
                radius: isDragging ? 8 : 0,
                y: isDragging ? 4 : 0
            )
            .animation(
                reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1),
                value: isFolderCreationReady
            )
            .highPriorityGesture(
                dragGesture(payload: payload, expandsFolders: expandsFolders)
            )
    }

    private var rootDropTarget: some View {
        HStack {
            Label(NSLocalizedString("根目录", comment: "模型目录顶层"), systemImage: "tray")
            Spacer()
            Image(systemName: "arrow.down.to.line")
                .foregroundStyle(.secondary)
        }
        .etFont(.footnote)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .background(dropHighlight(for: "root"))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ModelOrganizationDestinationFramesKey.self,
                    value: ["root": proxy.frame(in: .named(dragCoordinateSpace))]
                )
            }
        }
    }

    private func dragGesture(payload: String, expandsFolders: Bool) -> some Gesture {
        LongPressGesture(minimumDuration: 0.15)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(dragCoordinateSpace)))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginDragging(payload: payload, expandsFolders: expandsFolders)
                case .second(true, let dragValue):
                    beginDragging(payload: payload, expandsFolders: expandsFolders)
                    dragTranslation = dragValue?.translation ?? .zero
                    updateTarget(at: dragValue?.location, payload: payload)
                default:
                    break
                }
            }
            .onEnded { value in
                defer { finishDragging() }
                guard case .second(true, let dragValue) = value,
                      let location = dragValue?.location,
                      let targetID = destinationID(at: location, excluding: payload) else {
                    return
                }
                drop(payload: payload, on: targetID)
            }
    }

    private func beginDragging(payload: String, expandsFolders: Bool) {
        guard draggedPayload == nil else { return }
        draggedPayload = payload
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if expandsFolders {
            expandAllFolders()
        }
    }

    private func updateTarget(at location: CGPoint?, payload: String) {
        let nextTargetID = location.flatMap { destinationID(at: $0, excluding: payload) }
        guard targetedDestinationID != nextTargetID else { return }

        folderHoverTask?.cancel()
        targetedDestinationID = nextTargetID
        isFolderCreationReady = false

        guard let nextTargetID else { return }
        if let groupPath = ModelOrganizationDragPayload.groupName(from: nextTargetID) {
            setFolderExpanded(groupPath)
        }
        guard let draggedModelID = ModelOrganizationDragPayload.modelID(from: payload),
              let targetModelID = ModelOrganizationDragPayload.modelID(from: nextTargetID),
              draggedModelID != targetModelID else {
            return
        }

        folderHoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled,
                  draggedPayload == payload,
                  targetedDestinationID == nextTargetID else {
                return
            }
            isFolderCreationReady = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func destinationID(at location: CGPoint, excluding payload: String) -> String? {
        destinationFrames
            .filter { $0.key != payload && $0.value.contains(location) }
            .min { lhs, rhs in
                lhs.value.width * lhs.value.height < rhs.value.width * rhs.value.height
            }?
            .key
    }

    private func drop(payload: String, on targetID: String) {
        if targetID == "root" {
            _ = dropAtRootEnd([payload])
            return
        }
        _ = drop(
            payload: payload,
            on: targetID,
            among: organization.rootItems,
            parentGroupPath: nil
        )
    }

    private func drop(
        payload: String,
        on targetID: String,
        among items: [RunnableModelPickerOrganization.RootItem],
        parentGroupPath: String?
    ) -> Bool {
        for item in items {
            guard item.id != targetID else {
                switch item {
                case .model(let targetModelID):
                    return dropOnModel(
                        payload,
                        targetModelID: targetModelID,
                        parentGroupPath: parentGroupPath,
                        itemID: item.id
                    )
                case .group(let groupPath, _):
                    return dropOnFolder([payload], groupPath: groupPath)
                }
            }
            if case .group(let groupPath, let children) = item,
               drop(
                   payload: payload,
                   on: targetID,
                   among: children,
                   parentGroupPath: groupPath
               ) {
                return true
            }
        }
        return false
    }

    private func dropOnModel(
        _ payload: String,
        targetModelID: String,
        parentGroupPath: String?,
        itemID: String
    ) -> Bool {
        guard isFolderCreationReady,
              let draggedModelID = ModelOrganizationDragPayload.modelID(from: payload),
              draggedModelID != targetModelID else {
            return dropBeforeItem(
                [payload],
                parentGroupPath: parentGroupPath,
                itemID: itemID
            )
        }

        var updated = organization
        let groupPath = suggestedFolderName(in: parentGroupPath, organization: updated)
        updated.createGroup(groupPath)
        updated.moveModel(targetModelID, toGroup: groupPath)
        updated.moveModel(draggedModelID, toGroup: groupPath)
        setFolderExpanded(groupPath)
        persist(updated)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return true
    }

    private func finishDragging() {
        folderHoverTask?.cancel()
        folderHoverTask = nil
        draggedPayload = nil
        dragTranslation = .zero
        targetedDestinationID = nil
        isFolderCreationReady = false
    }

    private func dropBeforeItem(
        _ payloads: [String],
        parentGroupPath: String?,
        itemID: String
    ) -> Bool {
        guard let payload = payloads.first else { return false }
        var updated = organization
        if let modelID = ModelOrganizationDragPayload.modelID(from: payload) {
            updated.moveModel(modelID, toGroup: parentGroupPath, beforeItemID: itemID)
        } else if let groupPath = ModelOrganizationDragPayload.groupName(from: payload) {
            updated.moveGroup(groupPath, intoGroup: parentGroupPath, beforeItemID: itemID)
        } else {
            return false
        }
        persist(updated)
        return true
    }

    private func dropOnFolder(
        _ payloads: [String],
        groupPath: String
    ) -> Bool {
        guard let payload = payloads.first else { return false }
        var updated = organization
        if let modelID = ModelOrganizationDragPayload.modelID(from: payload) {
            updated.moveModel(modelID, toGroup: groupPath)
            setFolderExpanded(groupPath)
        } else if let draggedGroupPath = ModelOrganizationDragPayload.groupName(from: payload) {
            updated.moveGroup(draggedGroupPath, intoGroup: groupPath)
            setFolderExpanded(groupPath)
        } else {
            return false
        }
        persist(updated)
        return true
    }

    private func dropAtRootEnd(_ payloads: [String]) -> Bool {
        guard let payload = payloads.first else { return false }
        var updated = organization
        if let modelID = ModelOrganizationDragPayload.modelID(from: payload) {
            updated.moveModelToRoot(modelID)
        } else if let groupPath = ModelOrganizationDragPayload.groupName(from: payload) {
            updated.moveGroup(groupPath, intoGroup: nil)
        } else {
            return false
        }
        persist(updated)
        return true
    }

    private func folderExpansionID(_ groupPath: String) -> String {
        "\(provider.id.uuidString):\(groupPath)"
    }

    private func isFolderExpanded(_ groupPath: String) -> Bool {
        appConfig.iOSModelPickerExpandedGroupIDs.contains(folderExpansionID(groupPath))
    }

    private func setFolderExpanded(_ groupPath: String) {
        appConfig.iOSModelPickerExpandedGroupIDs.insert(folderExpansionID(groupPath))
    }

    private func expandAllFolders() {
        let expansionIDs = organization.allGroupPaths.map(folderExpansionID)
        appConfig.iOSModelPickerExpandedGroupIDs.formUnion(expansionIDs)
    }

    private func createFolder(named name: String) {
        guard let groupPath = normalizedGroupPath(name) else { return }
        if organization.allGroupPaths.contains(groupPath) {
            setFolderExpanded(groupPath)
            return
        }
        var updated = organization
        updated.createGroup(groupPath)
        setFolderExpanded(groupPath)
        persist(updated)
    }

    private func suggestedFolderName(
        in parentGroupPath: String?,
        organization: RunnableModelPickerOrganization
    ) -> String {
        let baseName = NSLocalizedString("新建文件夹", comment: "")
        var suffix = 1
        while true {
            let folderName = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            let path = [parentGroupPath, folderName].compactMap { $0 }.joined(separator: "/")
            if !organization.allGroupPaths.contains(path) {
                return path
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

    @ViewBuilder
    private func dropHighlight(for id: String) -> some View {
        if targetedDestinationID == id {
            Color.accentColor.opacity(0.14)
        }
    }

    private func persist(_ updated: RunnableModelPickerOrganization) {
        ChatService.shared.setModelPickerOrganization(
            updated,
            for: provider.id
        )
    }
}
