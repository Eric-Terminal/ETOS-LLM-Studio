// ============================================================================
// ChatServiceTypes.swift
// ============================================================================
// ETOS LLM Studio
//
// 存放 ChatService 相关的公共类型与轻量辅助函数，避免主服务文件继续膨胀。
// ============================================================================

import Foundation

/// 一个组合了 Provider 和 Model 的可运行实体，包含了发起 API 请求所需的所有信息。
public struct RunnableModel: Identifiable, Hashable {
    public var id: String { "\(provider.id.uuidString)-\(model.id.uuidString)" }
    public let provider: Provider
    public let model: Model

    public var requestBodyControlState: ModelRequestBodyControlState {
        ModelRequestBodyControlRuntimeStore.state(
            forModelKey: id,
            controls: model.requestBodyControls
        )
    }

    public var effectiveOverrideParameters: [String: JSONValue] {
        model.effectiveOverrideParameters(using: requestBodyControlState)
    }

    public func effectiveOverrideParameters(using state: ModelRequestBodyControlState) -> [String: JSONValue] {
        model.effectiveOverrideParameters(using: state)
    }

    public func saveRequestBodyControlState(_ state: ModelRequestBodyControlState) {
        ModelRequestBodyControlRuntimeStore.save(
            state,
            forModelKey: id,
            controls: model.requestBodyControls
        )
    }

    public init(provider: Provider, model: Model) {
        self.provider = provider
        self.model = model
    }

    // 只根据 ID 判断相等性，避免参数变化导致 Picker 匹配失败。
    public static func == (lhs: RunnableModel, rhs: RunnableModel) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// 按提供商预分组的模型集合，供选择器和排序界面直接渲染。
public struct RunnableModelProviderGroup: Identifiable, Hashable {
    public var id: UUID { provider.id }
    public let provider: Provider
    public let providerInitial: String
    public let models: [RunnableModel]
    public let pickerLayout: RunnableModelPickerLayout

    public init(provider: Provider, models: [RunnableModel]) {
        self.provider = provider
        self.providerInitial = ProviderMonogram.abbreviation(for: provider.name)
        self.models = models
        self.pickerLayout = RunnableModelPickerGrouping.layout(models: models)
    }
}

public struct RunnableModelPickerGroup: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let path: String
    public let items: [RunnableModelPickerRootItem]

    public var models: [RunnableModel] {
        items.flatMap { item in
            switch item {
            case .model(let model):
                return [model]
            case .group(let group):
                return group.models
            }
        }
    }
}

public indirect enum RunnableModelPickerRootItem: Identifiable, Hashable {
    case model(RunnableModel)
    case group(RunnableModelPickerGroup)

    public var id: String {
        switch self {
        case .model(let model):
            return "model:\(model.id)"
        case .group(let group):
            return "group:\(group.id)"
        }
    }
}

public struct RunnableModelPickerLayout: Hashable {
    public let rootItems: [RunnableModelPickerRootItem]

    public var ungroupedModels: [RunnableModel] {
        rootItems.compactMap { item in
            guard case .model(let model) = item else { return nil }
            return model
        }
    }

    public var groups: [RunnableModelPickerGroup] {
        rootItems.compactMap { item in
            guard case .group(let group) = item else { return nil }
            return group
        }
    }

    public init(rootItems: [RunnableModelPickerRootItem]) {
        self.rootItems = rootItems
    }

    public init(
        ungroupedModels: [RunnableModel],
        groups: [RunnableModelPickerGroup]
    ) {
        self.rootItems = ungroupedModels.map(RunnableModelPickerRootItem.model)
            + groups.map(RunnableModelPickerRootItem.group)
    }
}

public struct RunnableModelPickerPlacement: Hashable, Sendable {
    public let modelID: String
    public let pickerGroupName: String?

    public init(modelID: String, pickerGroupName: String?) {
        self.modelID = modelID
        self.pickerGroupName = Model.normalizedPickerGroupName(pickerGroupName)
    }
}

/// 用一个有序目录树表达模型选择器，目录路径直接保存到模型的分组字段。
public struct RunnableModelPickerOrganization: Hashable {
    public indirect enum RootItem: Identifiable, Hashable {
        case model(String)
        case group(path: String, children: [RootItem])

        public var id: String {
            switch self {
            case .model(let modelID):
                return Self.modelID(modelID)
            case .group(let path, _):
                return Self.groupID(path)
            }
        }

        public var groupPath: String? {
            guard case .group(let path, _) = self else { return nil }
            return path
        }

        public var name: String? {
            guard let groupPath else { return nil }
            return groupPath.split(separator: "/").last.map(String.init)
        }

        public var children: [RootItem] {
            guard case .group(_, let children) = self else { return [] }
            return children
        }

        public var modelIDs: [String] {
            switch self {
            case .model(let modelID):
                return [modelID]
            case .group(_, let children):
                return children.flatMap(\.modelIDs)
            }
        }

        public static func modelID(_ modelID: String) -> String {
            "model:\(modelID)"
        }

        public static func groupID(_ groupPath: String) -> String {
            "group:\(groupPath)"
        }
    }

    public private(set) var rootItems: [RootItem]

    public init(models: [RunnableModel]) {
        var items: [RootItem] = []
        for runnable in models {
            Self.insertNewModel(
                runnable.id,
                pathComponents: Self.pathComponents(runnable.model.pickerGroupName),
                parentComponents: [],
                into: &items
            )
        }
        self.rootItems = items
    }

    public var placements: [RunnableModelPickerPlacement] {
        Self.placements(in: rootItems, groupPath: nil)
    }

    public var allGroupPaths: Set<String> {
        Set(Self.groupPaths(in: rootItems))
    }

    public mutating func moveModelToRoot(
        _ modelID: String,
        beforeRootItemID: String? = nil
    ) {
        moveModel(modelID, toGroup: nil, beforeItemID: beforeRootItemID)
    }

    public mutating func moveModel(
        _ modelID: String,
        intoGroup groupPath: String,
        beforeModelID: String? = nil
    ) {
        moveModel(
            modelID,
            toGroup: groupPath,
            beforeItemID: beforeModelID.map(RootItem.modelID)
        )
    }

    public mutating func moveModel(
        _ modelID: String,
        toGroup groupPath: String?,
        beforeItemID: String? = nil
    ) {
        let normalizedGroupPath = Self.normalizedPath(groupPath)
        guard containsModel(modelID),
              normalizedGroupPath == nil || containsGroup(normalizedGroupPath!),
              beforeItemID != RootItem.modelID(modelID) else {
            return
        }

        Self.detachModel(modelID, from: &rootItems)
        Self.insert(
            .model(modelID),
            intoGroup: normalizedGroupPath,
            beforeItemID: beforeItemID,
            in: &rootItems
        )
        rootItems = Self.removingEmptyGroups(from: rootItems)
    }

    public mutating func moveGroup(
        _ groupPath: String,
        beforeRootItemID: String? = nil
    ) {
        moveGroup(groupPath, intoGroup: nil, beforeItemID: beforeRootItemID)
    }

    public mutating func moveGroup(
        _ groupPath: String,
        intoGroup destinationGroupPath: String?,
        beforeItemID: String? = nil
    ) {
        guard let sourcePath = Self.normalizedPath(groupPath),
              containsGroup(sourcePath) else {
            return
        }
        let destinationPath = Self.normalizedPath(destinationGroupPath)
        guard destinationPath == nil || containsGroup(destinationPath!),
              destinationPath != sourcePath,
              !(destinationPath?.hasPrefix(sourcePath + "/") ?? false),
              beforeItemID != RootItem.groupID(sourcePath) else {
            return
        }

        let folderName = sourcePath.split(separator: "/").last.map(String.init) ?? sourcePath
        let movedPath = [destinationPath, folderName].compactMap { $0 }.joined(separator: "/")
        if movedPath != sourcePath, containsGroup(movedPath) {
            return
        }

        guard let detachedGroup = Self.detachGroup(sourcePath, from: &rootItems) else { return }
        let rebasedGroup = Self.rebaseGroup(detachedGroup, from: sourcePath, to: movedPath)
        Self.insert(
            rebasedGroup,
            intoGroup: destinationPath,
            beforeItemID: beforeItemID,
            in: &rootItems
        )
        rootItems = Self.removingEmptyGroups(from: rootItems)
    }

    public mutating func reorderRootItems(_ orderedRootItemIDs: [String]) {
        let itemByID = Dictionary(uniqueKeysWithValues: rootItems.map { ($0.id, $0) })
        var seenIDs = Set<String>()
        var reordered = orderedRootItemIDs.compactMap { itemID -> RootItem? in
            guard seenIDs.insert(itemID).inserted else { return nil }
            return itemByID[itemID]
        }
        reordered.append(contentsOf: rootItems.filter { seenIDs.insert($0.id).inserted })
        rootItems = reordered
    }

    public mutating func reorderModels(
        inGroup groupPath: String,
        orderedModelIDs: [String]
    ) {
        guard let normalizedGroupPath = Self.normalizedPath(groupPath) else { return }
        Self.reorderModels(
            inGroup: normalizedGroupPath,
            orderedModelIDs: orderedModelIDs,
            items: &rootItems
        )
    }

    private func containsModel(_ modelID: String) -> Bool {
        rootItems.contains { $0.modelIDs.contains(modelID) }
    }

    private func containsGroup(_ groupPath: String) -> Bool {
        Self.containsGroup(groupPath, in: rootItems)
    }

    private static func pathComponents(_ path: String?) -> [String] {
        guard let normalizedPath = Model.normalizedPickerGroupName(path) else { return [] }
        return normalizedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedPath(_ path: String?) -> String? {
        let components = pathComponents(path)
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    private static func insertNewModel(
        _ modelID: String,
        pathComponents: [String],
        parentComponents: [String],
        into items: inout [RootItem]
    ) {
        guard let folderName = pathComponents.first else {
            items.append(.model(modelID))
            return
        }

        let folderComponents = parentComponents + [folderName]
        let folderPath = folderComponents.joined(separator: "/")
        if let folderIndex = items.firstIndex(where: { $0.groupPath == folderPath }),
           case .group(_, var children) = items[folderIndex] {
            insertNewModel(
                modelID,
                pathComponents: Array(pathComponents.dropFirst()),
                parentComponents: folderComponents,
                into: &children
            )
            items[folderIndex] = .group(path: folderPath, children: children)
            return
        }

        var children: [RootItem] = []
        insertNewModel(
            modelID,
            pathComponents: Array(pathComponents.dropFirst()),
            parentComponents: folderComponents,
            into: &children
        )
        items.append(.group(path: folderPath, children: children))
    }

    private static func placements(
        in items: [RootItem],
        groupPath: String?
    ) -> [RunnableModelPickerPlacement] {
        items.flatMap { item in
            switch item {
            case .model(let modelID):
                return [RunnableModelPickerPlacement(
                    modelID: modelID,
                    pickerGroupName: groupPath
                )]
            case .group(let path, let children):
                return placements(in: children, groupPath: path)
            }
        }
    }

    private static func groupPaths(in items: [RootItem]) -> [String] {
        items.flatMap { item -> [String] in
            guard case .group(let path, let children) = item else { return [] }
            return [path] + groupPaths(in: children)
        }
    }

    @discardableResult
    private static func detachModel(
        _ modelID: String,
        from items: inout [RootItem]
    ) -> Bool {
        for index in items.indices {
            switch items[index] {
            case .model(let currentModelID) where currentModelID == modelID:
                items.remove(at: index)
                return true
            case .group(let path, var children):
                if detachModel(modelID, from: &children) {
                    items[index] = .group(path: path, children: children)
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    private static func detachGroup(
        _ groupPath: String,
        from items: inout [RootItem]
    ) -> RootItem? {
        for index in items.indices {
            switch items[index] {
            case .group(let path, _) where path == groupPath:
                return items.remove(at: index)
            case .group(let path, var children):
                if let detached = detachGroup(groupPath, from: &children) {
                    items[index] = .group(path: path, children: children)
                    return detached
                }
            case .model:
                continue
            }
        }
        return nil
    }

    @discardableResult
    private static func insert(
        _ item: RootItem,
        intoGroup groupPath: String?,
        beforeItemID: String?,
        in items: inout [RootItem]
    ) -> Bool {
        guard let groupPath else {
            let destination = beforeItemID.flatMap { targetID in
                items.firstIndex { $0.id == targetID }
            } ?? items.endIndex
            items.insert(item, at: destination)
            return true
        }

        for index in items.indices {
            guard case .group(let path, var children) = items[index] else { continue }
            if path == groupPath {
                let destination = beforeItemID.flatMap { targetID in
                    children.firstIndex { $0.id == targetID }
                } ?? children.endIndex
                children.insert(item, at: destination)
                items[index] = .group(path: path, children: children)
                return true
            }
            if insert(
                item,
                intoGroup: groupPath,
                beforeItemID: beforeItemID,
                in: &children
            ) {
                items[index] = .group(path: path, children: children)
                return true
            }
        }
        return false
    }

    private static func containsGroup(_ groupPath: String, in items: [RootItem]) -> Bool {
        items.contains { item in
            guard case .group(let path, let children) = item else { return false }
            return path == groupPath || containsGroup(groupPath, in: children)
        }
    }

    private static func rebaseGroup(
        _ item: RootItem,
        from sourcePath: String,
        to destinationPath: String
    ) -> RootItem {
        guard case .group(let path, let children) = item else { return item }
        let rebasedPath = destinationPath + String(path.dropFirst(sourcePath.count))
        return .group(
            path: rebasedPath,
            children: children.map {
                rebaseGroup($0, from: sourcePath, to: destinationPath)
            }
        )
    }

    private static func removingEmptyGroups(from items: [RootItem]) -> [RootItem] {
        items.compactMap { item in
            guard case .group(let path, let children) = item else { return item }
            let remainingChildren = removingEmptyGroups(from: children)
            guard !remainingChildren.isEmpty else { return nil }
            return .group(path: path, children: remainingChildren)
        }
    }

    @discardableResult
    private static func reorderModels(
        inGroup groupPath: String,
        orderedModelIDs: [String],
        items: inout [RootItem]
    ) -> Bool {
        for index in items.indices {
            guard case .group(let path, var children) = items[index] else { continue }
            if path == groupPath {
                let modelItems = children.compactMap { item -> RootItem? in
                    guard case .model = item else { return nil }
                    return item
                }
                let modelByID = Dictionary(uniqueKeysWithValues: modelItems.map { ($0.id, $0) })
                var seenIDs = Set<String>()
                var reorderedModels = orderedModelIDs.compactMap { modelID -> RootItem? in
                    let itemID = RootItem.modelID(modelID)
                    guard seenIDs.insert(itemID).inserted else { return nil }
                    return modelByID[itemID]
                }
                reorderedModels.append(contentsOf: modelItems.filter {
                    seenIDs.insert($0.id).inserted
                })
                var iterator = reorderedModels.makeIterator()
                children = children.map { child in
                    guard case .model = child else { return child }
                    return iterator.next() ?? child
                }
                items[index] = .group(path: path, children: children)
                return true
            }
            if reorderModels(
                inGroup: groupPath,
                orderedModelIDs: orderedModelIDs,
                items: &children
            ) {
                items[index] = .group(path: path, children: children)
                return true
            }
        }
        return false
    }
}

public enum RunnableModelPickerGrouping {
    /// 根目录和文件夹顺序采用模型配置顺序，组内模型保持同一相对顺序。
    public static func layout(models: [RunnableModel]) -> RunnableModelPickerLayout {
        let organization = RunnableModelPickerOrganization(models: models)
        let modelByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        let providerID = models.first?.provider.id.uuidString ?? "unknown-provider"
        func pickerItem(_ item: RunnableModelPickerOrganization.RootItem) -> RunnableModelPickerRootItem? {
            switch item {
            case .model(let modelID):
                guard let model = modelByID[modelID] else { return nil }
                return .model(model)
            case .group(let groupPath, let children):
                let pickerItems = children.compactMap(pickerItem)
                guard !pickerItems.isEmpty else { return nil }
                return .group(
                    RunnableModelPickerGroup(
                        id: "\(providerID):\(groupPath)",
                        name: groupPath.split(separator: "/").last.map(String.init) ?? groupPath,
                        path: groupPath,
                        items: pickerItems
                    )
                )
            }
        }
        let rootItems = organization.rootItems.compactMap(pickerItem)
        return RunnableModelPickerLayout(rootItems: rootItems)
    }
}

public enum ProviderMonogram {
    /// 优先提取分词或驼峰单词的首字母；单个单词取前两个字符，中文先转换为拼音。
    public static func abbreviation(for providerName: String) -> String {
        let trimmedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "?" }

        let source = containsHanCharacters(trimmedName)
            ? transliteratedChinese(trimmedName)
            : trimmedName
        let words = wordComponents(in: source)
        guard let firstWord = words.first else { return "?" }

        if words.count > 1 {
            let initials = words.prefix(2).compactMap { $0.first }
            return String(initials).uppercased()
        }
        return String(firstWord.prefix(2)).uppercased()
    }

    private static func containsHanCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private static func transliteratedChinese(_ text: String) -> String {
        text.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripCombiningMarks, reverse: false)
            ?? text
    }

    private static func wordComponents(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }
            .flatMap(camelCaseComponents)
    }

    private static func camelCaseComponents(_ component: Substring) -> [String] {
        let characters = Array(component)
        guard characters.count > 1 else { return characters.isEmpty ? [] : [String(component)] }

        var result: [String] = []
        var wordStart = 0
        for index in 1..<characters.count {
            let previous = characters[index - 1]
            let current = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let startsAfterLowercase = previous.isLowercase && current.isUppercase
            let startsAfterAcronym = previous.isUppercase
                && current.isUppercase
                && next?.isLowercase == true
            guard startsAfterLowercase || startsAfterAcronym else { continue }

            result.append(String(characters[wordStart..<index]))
            wordStart = index
        }
        result.append(String(characters[wordStart...]))
        return result
    }
}

public enum RunnableModelGrouping {
    /// 保留模型在输入数组中的相对顺序，并按用户设置的提供商顺序生成分组。
    public static func groups(
        models: [RunnableModel],
        providerOrder: [Provider]
    ) -> [RunnableModelProviderGroup] {
        guard !models.isEmpty else { return [] }

        var modelsByProviderID: [UUID: [RunnableModel]] = [:]
        var providerByID = Dictionary(uniqueKeysWithValues: providerOrder.map { ($0.id, $0) })
        var orderedProviderIDs = providerOrder.map(\.id)
        var seenProviderIDs = Set(orderedProviderIDs)

        for model in models {
            modelsByProviderID[model.provider.id, default: []].append(model)
            providerByID[model.provider.id] = model.provider
            if seenProviderIDs.insert(model.provider.id).inserted {
                orderedProviderIDs.append(model.provider.id)
            }
        }

        return orderedProviderIDs.compactMap { providerID in
            guard let provider = providerByID[providerID],
                  let providerModels = modelsByProviderID[providerID],
                  !providerModels.isEmpty else {
                return nil
            }
            return RunnableModelProviderGroup(provider: provider, models: providerModels)
        }
    }
}

/// 根据最终请求覆盖参数决定响应模式，确保接收方式与实际发送的 `stream` 一致。
func resolvedRequestStreamingEnabled(
    preference: Bool,
    overrides: [String: JSONValue]
) -> Bool {
    guard case .bool(let overriddenValue)? = overrides["stream"] else {
        return preference
    }
    return overriddenValue
}

public enum SystemTimeInjectionPosition: String, CaseIterable, Identifiable, Sendable {
    case front
    case tail

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .front:
            return NSLocalizedString("前置发送", comment: "System time injection position before system prompt")
        case .tail:
            return NSLocalizedString("末尾发送", comment: "System time injection position tail system message")
        }
    }
}

public enum SystemTimeContextFormatter {
    public static func description(at date: Date = Date()) -> String {
        let localeFormatter = DateFormatter()
        localeFormatter.calendar = Calendar(identifier: .gregorian)
        localeFormatter.locale = Locale(identifier: "en_US_POSIX")
        localeFormatter.timeZone = TimeZone.current
        localeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let localTime = localeFormatter.string(from: date)
        let timeZoneIdentifier = TimeZone.current.identifier

        return String(
            format: NSLocalizedString("当前系统时间%@，时区%@", comment: "System time line for model prompt."),
            localTime,
            timeZoneIdentifier
        )
    }
}

func moveElements<T>(in array: inout [T], fromOffsets offsets: IndexSet, toOffset destination: Int) {
    let sortedOffsets = offsets.sorted()
    guard !sortedOffsets.isEmpty else { return }
    guard sortedOffsets.allSatisfy({ $0 >= 0 && $0 < array.count }) else { return }
    guard destination >= 0 && destination <= array.count else { return }

    let movedItems = sortedOffsets.map { array[$0] }
    for index in sortedOffsets.reversed() {
        array.remove(at: index)
    }

    let removedBeforeDestination = sortedOffsets.filter { $0 < destination }.count
    let insertionIndex = max(0, min(destination - removedBeforeDestination, array.count))
    array.insert(contentsOf: movedItems, at: insertionIndex)
}
