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

private struct WatchProviderModelOrderDetailView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var targetedDestinationID: String?
    @State private var draggedPayload: String?
    @State private var destinationFrames: [String: CGRect] = [:]
    let provider: Provider

    private let dragCoordinateSpace = "watch-model-organization"

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("模型顺序", comment: "")),
                footer: Text(NSLocalizedString(
                    "长按条目，再拖到文件夹或根目录。拖动模型时会展开全部文件夹。",
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
                        let payload = ModelOrganizationDragPayload.model(modelID)
                        modelOrderRow(model, depth: depth)
                            .opacity(draggedPayload == payload ? 0.55 : 1)
                            .highPriorityGesture(dragGesture(payload: payload, expandsFolders: true))
                            .background(dropHighlight(for: item.id))
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: ModelOrganizationDestinationFramesKey.self,
                                        value: [item.id: proxy.frame(in: .named(dragCoordinateSpace))]
                                    )
                                }
                            }
                    }
                case .group(let groupPath, let children):
                    let payload = ModelOrganizationDragPayload.group(groupPath)
                    folderRow(
                        groupPath: groupPath,
                        modelCount: item.modelIDs.count,
                        depth: depth
                    )
                    .opacity(draggedPayload == payload ? 0.55 : 1)
                    .highPriorityGesture(dragGesture(payload: payload, expandsFolders: false))
                    .background(dropHighlight(for: item.id))
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ModelOrganizationDestinationFramesKey.self,
                                value: [item.id: proxy.frame(in: .named(dragCoordinateSpace))]
                            )
                        }
                    }

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
            if appConfig.watchModelPickerExpandedGroupIDs.contains(expansionID) {
                appConfig.watchModelPickerExpandedGroupIDs.remove(expansionID)
            } else {
                appConfig.watchModelPickerExpandedGroupIDs.insert(expansionID)
            }
        } label: {
            HStack {
                Label(
                    groupPath.split(separator: "/").last.map(String.init) ?? groupPath,
                    systemImage: isFolderExpanded(groupPath) ? "folder.fill" : "folder"
                )
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(modelCount)")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)

                Image(systemName: isFolderExpanded(groupPath) ? "chevron.down" : "chevron.right")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)

                dragHandle
            }
            .contentShape(Rectangle())
            .padding(.leading, CGFloat(depth) * 8)
        }
        .buttonStyle(.plain)
    }

    private func modelOrderRow(_ runnable: RunnableModel, depth: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
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
                ),
                spacing: 2
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if !runnable.model.isActivated {
                Text(NSLocalizedString("未启用", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            dragHandle
        }
        .contentShape(Rectangle())
        .padding(.leading, CGFloat(depth) * 8)
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .etFont(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
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

    private func dragGesture(
        payload: String,
        expandsFolders: Bool
    ) -> some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(dragCoordinateSpace)))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginDragging(payload: payload, expandsFolders: expandsFolders)
                case .second(true, let dragValue):
                    beginDragging(payload: payload, expandsFolders: expandsFolders)
                    updateTarget(at: dragValue?.location)
                default:
                    break
                }
            }
            .onEnded { value in
                defer { finishDragging() }
                guard case .second(true, let dragValue) = value,
                      let location = dragValue?.location,
                      let targetID = destinationID(at: location) else {
                    return
                }
                drop(payload: payload, on: targetID)
            }
    }

    private func beginDragging(payload: String, expandsFolders: Bool) {
        guard draggedPayload == nil else { return }
        draggedPayload = payload
        if expandsFolders {
            expandAllFolders()
        }
    }

    private func updateTarget(at location: CGPoint?) {
        targetedDestinationID = location.flatMap(destinationID)
    }

    private func destinationID(at location: CGPoint) -> String? {
        destinationFrames.first { $0.value.contains(location) }?.key
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
                case .model:
                    return dropBeforeItem(
                        [payload],
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

    private func finishDragging() {
        draggedPayload = nil
        targetedDestinationID = nil
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
        appConfig.watchModelPickerExpandedGroupIDs.contains(folderExpansionID(groupPath))
    }

    private func setFolderExpanded(_ groupPath: String) {
        appConfig.watchModelPickerExpandedGroupIDs.insert(folderExpansionID(groupPath))
    }

    private func expandAllFolders() {
        let expansionIDs = organization.allGroupPaths.map(folderExpansionID)
        appConfig.watchModelPickerExpandedGroupIDs.formUnion(expansionIDs)
    }

    @ViewBuilder
    private func dropHighlight(for id: String) -> some View {
        if targetedDestinationID == id {
            Color.accentColor.opacity(0.14)
        }
    }

    private func persist(_ updated: RunnableModelPickerOrganization) {
        ChatService.shared.setModelPickerOrganization(
            updated.placements,
            for: provider.id
        )
    }
}
