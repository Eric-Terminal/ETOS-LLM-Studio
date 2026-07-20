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

private enum ModelOrganizationActionItem {
    case model(String)
    case group(String)

    var organizationID: String {
        switch self {
        case .model(let modelID):
            return RunnableModelPickerOrganization.RootItem.modelID(modelID)
        case .group(let groupPath):
            return RunnableModelPickerOrganization.RootItem.groupID(groupPath)
        }
    }
}

private struct ModelOrganizationActionContext: Identifiable {
    let item: ModelOrganizationActionItem
    let parentGroupPath: String?
    let title: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let destinationGroupPaths: [String]

    var id: String { item.organizationID }
}

private struct WatchProviderModelOrderDetailView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var activeActionContext: ModelOrganizationActionContext?
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    let provider: Provider

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("模型顺序", comment: "")),
                footer: Text(NSLocalizedString(
                    "点击更多按钮调整顺序或移动到文件夹；使用右上角按钮新建文件夹。",
                    comment: "模型目录手动整理提示"
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
                }
            }
        }
        .navigationTitle(provider.name)
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
        .sheet(item: $activeActionContext) { context in
            actionSheet(for: context)
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
                        modelOrderRow(
                            model,
                            depth: depth,
                            actionItem: .model(modelID),
                            parentGroupPath: parentGroupPath
                        )
                    }
                case .group(let groupPath, let children):
                    folderRow(
                        groupPath: groupPath,
                        depth: depth,
                        parentGroupPath: parentGroupPath
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

    private func folderRow(
        groupPath: String,
        depth: Int,
        parentGroupPath: String?
    ) -> some View {
        HStack {
            Button {
                toggleFolder(groupPath)
            } label: {
                HStack {
                    Label(
                        groupPath.split(separator: "/").last.map(String.init) ?? groupPath,
                        systemImage: isFolderExpanded(groupPath) ? "folder.fill" : "folder"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: isFolderExpanded(groupPath) ? "chevron.down" : "chevron.right")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                presentActions(
                    for: .group(groupPath),
                    parentGroupPath: parentGroupPath
                )
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(NSLocalizedString("更多", comment: ""))
        }
        .padding(.leading, CGFloat(depth) * 8)
    }

    private func modelOrderRow(
        _ runnable: RunnableModel,
        depth: Int,
        actionItem: ModelOrganizationActionItem,
        parentGroupPath: String?
    ) -> some View {
        HStack(alignment: .center, spacing: 6) {
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

            Button {
                presentActions(
                    for: actionItem,
                    parentGroupPath: parentGroupPath
                )
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(NSLocalizedString("更多", comment: ""))
        }
        .contentShape(Rectangle())
        .padding(.leading, CGFloat(depth) * 8)
    }

    private func actionSheet(for context: ModelOrganizationActionContext) -> some View {
        NavigationStack {
            List {
                Section(NSLocalizedString("模型顺序", comment: "")) {
                    Button {
                        move(context, by: -1)
                    } label: {
                        Label(NSLocalizedString("上移", comment: ""), systemImage: "arrow.up")
                    }
                    .disabled(!context.canMoveUp)

                    Button {
                        move(context, by: 1)
                    } label: {
                        Label(NSLocalizedString("下移", comment: ""), systemImage: "arrow.down")
                    }
                    .disabled(!context.canMoveDown)
                }

                Section(NSLocalizedString("移动到文件夹", comment: "")) {
                    Button {
                        move(context, toGroup: nil)
                    } label: {
                        Label(
                            NSLocalizedString("根目录", comment: "模型目录顶层"),
                            systemImage: context.parentGroupPath == nil ? "checkmark" : "tray"
                        )
                    }
                    .disabled(context.parentGroupPath == nil)

                    ForEach(context.destinationGroupPaths, id: \.self) { groupPath in
                        Button {
                            move(context, toGroup: groupPath)
                        } label: {
                            Label(
                                groupPath,
                                systemImage: context.parentGroupPath == groupPath ? "checkmark" : "folder"
                            )
                        }
                        .disabled(context.parentGroupPath == groupPath)
                    }
                }
            }
            .navigationTitle(context.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        activeActionContext = nil
                    }
                }
            }
        }
    }

    private func presentActions(
        for item: ModelOrganizationActionItem,
        parentGroupPath: String?
    ) {
        activeActionContext = makeActionContext(
            for: item,
            parentGroupPath: parentGroupPath,
            organization: organization
        )
    }

    private func makeActionContext(
        for item: ModelOrganizationActionItem,
        parentGroupPath: String?,
        organization: RunnableModelPickerOrganization
    ) -> ModelOrganizationActionContext {
        let siblings = organizationItems(
            in: parentGroupPath,
            organization: organization
        )
        let index = siblings.firstIndex { $0.id == item.organizationID }
        let title: String
        let destinations: [String]

        switch item {
        case .model(let modelID):
            title = viewModel.configuredModelsByID[modelID]?.model.displayName ?? modelID
            destinations = organization.orderedGroupPaths
        case .group(let groupPath):
            title = groupPath.split(separator: "/").last.map(String.init) ?? groupPath
            destinations = organization.orderedGroupPaths.filter {
                $0 != groupPath && !$0.hasPrefix(groupPath + "/")
            }
        }

        return ModelOrganizationActionContext(
            item: item,
            parentGroupPath: parentGroupPath,
            title: title,
            canMoveUp: (index ?? 0) > 0,
            canMoveDown: index.map { $0 < siblings.count - 1 } ?? false,
            destinationGroupPaths: destinations
        )
    }

    private func organizationItems(
        in groupPath: String?,
        organization: RunnableModelPickerOrganization
    ) -> [RunnableModelPickerOrganization.RootItem] {
        guard let groupPath else { return organization.rootItems }

        func children(
            of targetPath: String,
            in items: [RunnableModelPickerOrganization.RootItem]
        ) -> [RunnableModelPickerOrganization.RootItem]? {
            for item in items {
                guard case .group(let path, let nestedItems) = item else { continue }
                if path == targetPath {
                    return nestedItems
                }
                if let result = children(of: targetPath, in: nestedItems) {
                    return result
                }
            }
            return nil
        }

        return children(of: groupPath, in: organization.rootItems) ?? []
    }

    private func move(
        _ context: ModelOrganizationActionContext,
        by offset: Int
    ) {
        let siblings = organizationItems(
            in: context.parentGroupPath,
            organization: organization
        )
        guard let currentIndex = siblings.firstIndex(where: {
            $0.id == context.item.organizationID
        }) else {
            activeActionContext = nil
            return
        }

        let targetIndex = currentIndex + offset
        guard siblings.indices.contains(targetIndex) else {
            activeActionContext = nil
            return
        }

        let beforeItemID: String?
        if offset < 0 {
            beforeItemID = siblings[targetIndex].id
        } else {
            let followingIndex = currentIndex + 2
            beforeItemID = siblings.indices.contains(followingIndex)
                ? siblings[followingIndex].id
                : nil
        }

        var updated = organization
        switch context.item {
        case .model(let modelID):
            updated.moveModel(
                modelID,
                toGroup: context.parentGroupPath,
                beforeItemID: beforeItemID
            )
        case .group(let groupPath):
            updated.moveGroup(
                groupPath,
                intoGroup: context.parentGroupPath,
                beforeItemID: beforeItemID
            )
        }
        persist(updated)
        activeActionContext = nil
    }

    private func move(
        _ context: ModelOrganizationActionContext,
        toGroup destinationGroupPath: String?
    ) {
        guard destinationGroupPath != context.parentGroupPath else {
            activeActionContext = nil
            return
        }

        var updated = organization
        switch context.item {
        case .model(let modelID):
            updated.moveModel(
                modelID,
                toGroup: destinationGroupPath
            )
            if let destinationGroupPath {
                setFolderExpanded(destinationGroupPath)
            }
        case .group(let groupPath):
            updated.moveGroup(
                groupPath,
                intoGroup: destinationGroupPath
            )
            let folderName = groupPath.split(separator: "/").last.map(String.init) ?? groupPath
            let movedPath = [destinationGroupPath, folderName]
                .compactMap { $0 }
                .joined(separator: "/")
            setFolderExpanded(movedPath)
        }
        persist(updated)
        activeActionContext = nil
    }

    private func folderExpansionID(_ groupPath: String) -> String {
        "\(provider.id.uuidString):\(groupPath)"
    }

    private func isFolderExpanded(_ groupPath: String) -> Bool {
        appConfig.watchModelPickerExpandedGroupIDs.contains(folderExpansionID(groupPath))
    }

    private func toggleFolder(_ groupPath: String) {
        let expansionID = folderExpansionID(groupPath)
        if appConfig.watchModelPickerExpandedGroupIDs.contains(expansionID) {
            appConfig.watchModelPickerExpandedGroupIDs.remove(expansionID)
        } else {
            appConfig.watchModelPickerExpandedGroupIDs.insert(expansionID)
        }
    }

    private func setFolderExpanded(_ groupPath: String) {
        appConfig.watchModelPickerExpandedGroupIDs.insert(folderExpansionID(groupPath))
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

    private func persist(_ updated: RunnableModelPickerOrganization) {
        ChatService.shared.setModelPickerOrganization(
            updated,
            for: provider.id
        )
    }
}
