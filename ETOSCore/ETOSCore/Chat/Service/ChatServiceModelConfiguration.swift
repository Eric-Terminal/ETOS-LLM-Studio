// ============================================================================
// ChatServiceModelConfiguration.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的模型列表、模型排序、Provider 重载与当前模型选择。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    public var configuredRunnableModels: [RunnableModel] {
        let remoteModels = providers.flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0) }
        }
        return orderedRunnableModels(from: remoteModels)
    }

    public var activatedRunnableModels: [RunnableModel] {
        configuredRunnableModels.filter { runnable in
            guard runnable.model.isActivated else { return false }
            guard LocalModelProviderBridge.isLocalRunnableModel(runnable) else { return true }
            return localModelRecord(for: runnable)?.isActivated == true
        }
    }

    public var activatedConversationModels: [RunnableModel] {
        activatedRunnableModels.filter { $0.model.isConversationModel }
    }

    public var activatedChatModels: [RunnableModel] {
        activatedRunnableModels.filter { $0.model.isChatModel }
    }

    public var activatedSpeechModels: [RunnableModel] {
        // 语音服务由用户在对应设置页显式选择；旧能力标记优先，否则展示已配置的聊天模型。
        let configuredModels = configuredRunnableModels
        let speechCapable = configuredModels.filter { $0.model.supportsSpeechToText }
        var candidates = speechCapable.isEmpty
            ? configuredModels.filter { $0.model.isChatModel }
            : speechCapable
        if !candidates.contains(where: { $0.id == Self.systemSpeechRecognizerRunnableModel.id }) {
            candidates.insert(Self.systemSpeechRecognizerRunnableModel, at: 0)
        }
        return candidates
    }

    public var activatedTTSModels: [RunnableModel] {
        // TTS 不再要求模型承担独立类型，保留旧能力标记的优先级以兼容已有配置。
        let configuredModels = configuredRunnableModels
        let ttsCapable = configuredModels.filter { $0.model.supportsTextToSpeech }
        return ttsCapable.isEmpty
            ? configuredModels.filter { $0.model.isChatModel }
            : ttsCapable
    }

    public var activatedOCRModels: [RunnableModel] {
        activatedChatModels.filter { $0.model.supportsVisionInput }
    }

    func resolveSelectedSpeechModel() -> RunnableModel? {
        let storedIdentifier = Persistence.readAppConfigText(key: AppConfigKey.speechModelIdentifier.rawValue) ?? ""
        if !storedIdentifier.isEmpty,
           let match = activatedSpeechModels.first(where: { $0.id == storedIdentifier }) {
            return match
        }
        return activatedSpeechModels.first
    }

    public func resolveSelectedTTSModel() -> RunnableModel? {
        let storedIdentifier = Persistence.readAppConfigText(key: AppConfigKey.ttsModelIdentifier.rawValue) ?? ""
        if !storedIdentifier.isEmpty,
           let match = activatedTTSModels.first(where: { $0.id == storedIdentifier }) {
            return match
        }
        return activatedTTSModels.first
    }

    func orderedRunnableModels(from models: [RunnableModel]) -> [RunnableModel] {
        guard !models.isEmpty else { return [] }
        let currentIDs = models.map(\.id)
        let storedIDs = AppConfigStore.stringArrayValue(
            for: .modelOrderRunnableModels,
            legacyUserDefaultsKey: Self.modelOrderStorageKey,
            defaultValue: []
        ) ?? []
        let providerIDByModelID = Dictionary(uniqueKeysWithValues: models.map {
            ($0.id, $0.provider.id.uuidString)
        })
        let orderedIDs = ModelOrderIndex.hierarchicalOrder(
            storedModelIDs: storedIDs,
            currentModelIDs: currentIDs,
            providerIDByModelID: providerIDByModelID,
            orderedProviderIDs: providers.map { $0.id.uuidString }
        )
        let modelByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        return orderedIDs.compactMap { modelByID[$0] }
    }

    func reconcileStoredModelOrder() {
        let currentIDs = providers.flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0).id }
        }
        let storedIDs = AppConfigStore.stringArrayValue(
            for: .modelOrderRunnableModels,
            legacyUserDefaultsKey: Self.modelOrderStorageKey,
            defaultValue: []
        ) ?? []
        let mergedIDs = ModelOrderIndex.merge(storedIDs: storedIDs, currentIDs: currentIDs)
        guard mergedIDs != storedIDs else { return }
        AppConfigStore.persistStringArray(mergedIDs, for: .modelOrderRunnableModels)
    }

    func localModelRecord(for runnableModel: RunnableModel) -> LocalModelRecord? {
        guard LocalModelProviderBridge.isLocalRunnableModel(runnableModel),
              let recordID = LocalModelProviderBridge.localRecordID(from: runnableModel.id) else {
            return nil
        }
        return localModelStore.models.first { $0.id == recordID && localModelStore.fileExists(for: $0) }
    }

    func reconcileStoredProviderOrder() {
        let currentIDs = providers.map { $0.id.uuidString }
        let storedIDs = AppConfigStore.stringArrayValue(
            for: .providerOrderIDs,
            defaultValue: []
        ) ?? []
        let mergedIDs = ModelOrderIndex.merge(storedIDs: storedIDs, currentIDs: currentIDs)
        guard mergedIDs != storedIDs else { return }
        AppConfigStore.persistStringArray(mergedIDs, for: .providerOrderIDs)
    }

    public func setConfiguredModelOrder(_ orderedModelIDs: [String], notifyChange: Bool = true) {
        let currentIDs = providers.flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0).id }
        }
        let mergedIDs = ModelOrderIndex.merge(storedIDs: orderedModelIDs, currentIDs: currentIDs)
        AppConfigStore.persistStringArray(mergedIDs, for: .modelOrderRunnableModels)
        if notifyChange {
            providersSubject.send(providers)
        }
    }

    /// 只更新指定提供商内部的模型顺序，不扰动其他提供商的相对位置。
    public func setConfiguredModelOrder(
        _ orderedModelIDs: [String],
        for providerID: UUID,
        notifyChange: Bool = true
    ) {
        let currentModels = configuredRunnableModels
        let currentProviderModelIDs = currentModels
            .filter { $0.provider.id == providerID }
            .map(\.id)
        guard !currentProviderModelIDs.isEmpty else { return }

        let mergedProviderModelIDs = ModelOrderIndex.merge(
            storedIDs: orderedModelIDs,
            currentIDs: currentProviderModelIDs
        )
        var replacementIndex = 0
        let mergedAllModelIDs = currentModels.map { runnable in
            guard runnable.provider.id == providerID else { return runnable.id }
            defer { replacementIndex += 1 }
            return mergedProviderModelIDs[replacementIndex]
        }
        setConfiguredModelOrder(mergedAllModelIDs, notifyChange: notifyChange)
    }

    /// 同时保存指定提供商的根目录顺序、文件夹顺序和模型分组归属。
    @MainActor
    public func setModelPickerOrganization(
        _ organization: RunnableModelPickerOrganization,
        for providerID: UUID
    ) {
        guard let providerIndex = providers.firstIndex(where: { $0.id == providerID }) else {
            return
        }

        let placements = organization.placements
        let placementByModelID = Dictionary(
            uniqueKeysWithValues: placements.map { ($0.modelID, $0) }
        )
        var updatedProvider = providers[providerIndex]
        updatedProvider.models = updatedProvider.models.map { model in
            var updatedModel = model
            let runnableID = RunnableModel(provider: updatedProvider, model: model).id
            if let placement = placementByModelID[runnableID] {
                updatedModel.pickerGroupName = placement.pickerGroupName
            }
            return updatedModel
        }

        setConfiguredModelOrder(
            placements.map(\.modelID),
            for: providerID,
            notifyChange: false
        )
        AppConfigStore.shared.setModelPickerFolderPaths(
            organization.orderedGroupPaths,
            for: providerID
        )
        if LocalModelProviderBridge.isLocalProvider(updatedProvider) {
            persistLocalProviderModelChanges(updatedProvider)
            updatedProvider = LocalModelProviderBridge.provider(
                records: localModelStore.models,
                preserving: updatedProvider,
                preferRecordBasics: false
            )
        }
        ConfigLoader.saveProvider(updatedProvider)
        reloadProviders()
    }

    public func setProviderOrder(_ orderedProviderIDs: [UUID], notifyChange: Bool = true) {
        let currentIDs = providers.map { $0.id.uuidString }
        let requestedIDs = orderedProviderIDs.map(\.uuidString)
        let mergedIDs = ModelOrderIndex.merge(storedIDs: requestedIDs, currentIDs: currentIDs)
        AppConfigStore.persistStringArray(mergedIDs, for: .providerOrderIDs)

        let rankByID = Dictionary(uniqueKeysWithValues: mergedIDs.enumerated().map { ($1, $0) })
        providers.sort { lhs, rhs in
            let lhsRank = rankByID[lhs.id.uuidString] ?? Int.max
            let rhsRank = rankByID[rhs.id.uuidString] ?? Int.max
            if lhsRank == rhsRank {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhsRank < rhsRank
        }
        if notifyChange {
            providersSubject.send(providers)
        }
    }

    func persistSelectedRunnableModelID(_ modelID: String?) {
        AppConfigStore.persistSynchronously(
            .text(modelID ?? ""),
            for: .selectedRunnableModelID
        )
    }

    public func reloadAppConfigBackedModelState() {
        providers = synchronizedProviders(preferRecordBasics: true)
        reconcileStoredProviderOrder()
        reconcileStoredModelOrder()
        providersSubject.send(providers)
        let selectedID = AppConfigStore.textValue(
            for: .selectedRunnableModelID,
            legacyUserDefaultsKey: Self.selectedRunnableModelStorageKey
        )
        let nextModel = selectedID.isEmpty
            ? activatedConversationModels.first
            : activatedConversationModels.first { $0.id == selectedID } ?? activatedConversationModels.first
        selectedModelSubject.send(nextModel)
    }

    public func reloadLocalModelsAndAppConfigBackedModelState() {
        _ = localModelStore.reload()
        reloadAppConfigBackedModelState()
    }

    public func reloadLocalModelsAndProvidersIfNeeded() {
        guard localModelStore.reload() else { return }
        reloadProviders()
    }

    public func reloadProviders() {
        logger.info("正在重新加载提供商配置...")
        let currentSelectedID = selectedModelSubject.value?.id

        self.providers = synchronizedProviders(preferRecordBasics: true)
        self.reconcileStoredProviderOrder()
        self.reconcileStoredModelOrder()

        let allRunnable = activatedConversationModels
        var newSelectedModel: RunnableModel?
        if let currentID = currentSelectedID {
            newSelectedModel = allRunnable.first { $0.id == currentID }
        }
        if newSelectedModel == nil {
            newSelectedModel = allRunnable.first
        }

        selectedModelSubject.send(newSelectedModel)
        persistSelectedRunnableModelID(newSelectedModel?.id)
        providersSubject.send(self.providers)

        logger.info("提供商配置已刷新，并已更新当前选中模型。")
    }

    public func deleteProvider(_ provider: Provider) {
        if LocalModelProviderBridge.isLocalProvider(provider) {
            localModelStore.setProviderEnabled(false)
            reloadProviders()
            return
        }
        ConfigLoader.deleteProvider(provider)
        reloadProviders()
    }

    public func setLocalModelsEnabled(_ isEnabled: Bool) {
        localModelStore.setProviderEnabled(isEnabled)
        reloadProviders()
    }

    public func setSelectedModel(_ model: RunnableModel?) {
        guard model?.model.isConversationModel ?? true else { return }
        guard selectedModelSubject.value?.id != model?.id else { return }
        selectedModelSubject.send(model)
        persistSelectedRunnableModelID(model?.id)
        logger.info("已将模型切换为: \(model?.model.displayName ?? "无")")
        AppLog.userOperation(
            category: NSLocalizedString("模型", comment: "App log category"),
            action: NSLocalizedString("切换模型", comment: "App log action"),
            payload: [
                "provider": model?.provider.name ?? NSLocalizedString("无", comment: "App log empty value"),
                "model": model?.model.displayName ?? NSLocalizedString("无", comment: "App log empty value")
            ]
        )
    }

    public func saveAndReloadProviders(from providers: [Provider]) {
        logger.info("正在保存并重载提供商配置...")
        self.providers = providers
        for provider in self.providers {
            ConfigLoader.saveProvider(provider)
        }
        self.reloadProviders()
    }

    func synchronizedProviders(preferRecordBasics: Bool) -> [Provider] {
        let storedProviders = ConfigLoader.loadProviders()
        return LocalModelProviderBridge.applyingLocalProvider(
            to: storedProviders,
            records: localModelStore.models,
            isEnabled: localModelStore.isProviderEnabled,
            preferRecordBasics: preferRecordBasics
        )
    }

    func persistLocalProviderModelChanges(_ provider: Provider) {
        guard LocalModelProviderBridge.isLocalProvider(provider) else { return }
        for model in provider.models {
            localModelStore.updateFromProviderModel(model)
        }
    }

    public func saveProviderFromManagement(_ provider: Provider) {
        if LocalModelProviderBridge.isLocalProvider(provider) {
            if !localModelStore.isProviderEnabled {
                localModelStore.setProviderEnabled(true)
            }
            persistLocalProviderModelChanges(provider)
            let normalizedProvider = LocalModelProviderBridge.provider(
                records: localModelStore.models,
                preserving: provider,
                preferRecordBasics: false
            )
            ConfigLoader.saveProvider(normalizedProvider)
            reloadProviders()
            return
        }
        ConfigLoader.saveProvider(provider)
        reloadProviders()
    }

    public func moveConfiguredModel(fromPosition source: Int, toPosition destination: Int) {
        let orderedModels = configuredRunnableModels
        let modelCount = orderedModels.count
        guard modelCount > 1 else { return }
        guard source >= 0 && source < modelCount else { return }
        guard destination >= 0 && destination < modelCount else { return }
        guard source != destination else { return }

        let reorderedIDs = ModelOrderIndex.move(
            ids: orderedModels.map(\.id),
            fromPosition: source,
            toPosition: destination
        )
        setConfiguredModelOrder(reorderedIDs)
    }

    public func moveConfiguredModels(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var orderedModels = configuredRunnableModels
        let modelCount = orderedModels.count
        guard modelCount > 1 else { return }
        guard destination >= 0 && destination <= modelCount else { return }
        guard offsets.allSatisfy({ $0 >= 0 && $0 < modelCount }) else { return }
        guard !offsets.isEmpty else { return }

        moveElements(in: &orderedModels, fromOffsets: offsets, toOffset: destination)
        setConfiguredModelOrder(orderedModels.map(\.id))
    }
}
