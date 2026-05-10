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
        let allModels = providers.flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0) }
        }
        return orderedRunnableModels(from: allModels)
    }

    public var activatedRunnableModels: [RunnableModel] {
        configuredRunnableModels.filter { $0.model.isActivated }
    }

    public var activatedSpeechModels: [RunnableModel] {
        let speechCapable = activatedRunnableModels.filter { $0.model.supportsSpeechToText }
        var candidates = speechCapable.isEmpty ? activatedRunnableModels : speechCapable
        if !candidates.contains(where: { $0.id == Self.systemSpeechRecognizerRunnableModel.id }) {
            candidates.insert(Self.systemSpeechRecognizerRunnableModel, at: 0)
        }
        return candidates
    }

    public var activatedTTSModels: [RunnableModel] {
        let ttsCapable = activatedRunnableModels.filter { $0.model.supportsTextToSpeech }
        return ttsCapable
    }

    public var activatedOCRModels: [RunnableModel] {
        activatedRunnableModels.filter { $0.model.isChatModel && $0.model.supportsVisionInput }
    }

    func resolveSelectedSpeechModel() -> RunnableModel? {
        let storedIdentifier = UserDefaults.standard.string(forKey: "speechModelIdentifier")
        if let identifier = storedIdentifier,
           let match = activatedSpeechModels.first(where: { $0.id == identifier }) {
            return match
        }
        return activatedSpeechModels.first
    }

    public func resolveSelectedTTSModel() -> RunnableModel? {
        let storedIdentifier = UserDefaults.standard.string(forKey: Self.ttsModelStorageKey) ?? ""
        if !storedIdentifier.isEmpty,
           let match = activatedTTSModels.first(where: { $0.id == storedIdentifier }) {
            return match
        }
        return activatedTTSModels.first
    }

    func orderedRunnableModels(from models: [RunnableModel]) -> [RunnableModel] {
        guard !models.isEmpty else { return [] }
        let currentIDs = models.map(\.id)
        let storedIDs = UserDefaults.standard.stringArray(forKey: Self.modelOrderStorageKey) ?? []
        let mergedIDs = ModelOrderIndex.merge(storedIDs: storedIDs, currentIDs: currentIDs)
        let rankByID = Dictionary(uniqueKeysWithValues: mergedIDs.enumerated().map { ($1, $0) })

        return models.enumerated()
            .sorted { lhs, rhs in
                let leftRank = rankByID[lhs.element.id] ?? Int.max
                let rightRank = rankByID[rhs.element.id] ?? Int.max
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func reconcileStoredModelOrder() {
        let currentIDs = providers.flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0).id }
        }
        let storedIDs = UserDefaults.standard.stringArray(forKey: Self.modelOrderStorageKey) ?? []
        let mergedIDs = ModelOrderIndex.merge(storedIDs: storedIDs, currentIDs: currentIDs)
        guard mergedIDs != storedIDs else { return }
        UserDefaults.standard.set(mergedIDs, forKey: Self.modelOrderStorageKey)
    }

    public func setConfiguredModelOrder(_ orderedModelIDs: [String], notifyChange: Bool = true) {
        let currentIDs = providers.flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0).id }
        }
        let mergedIDs = ModelOrderIndex.merge(storedIDs: orderedModelIDs, currentIDs: currentIDs)
        UserDefaults.standard.set(mergedIDs, forKey: Self.modelOrderStorageKey)
        if notifyChange {
            providersSubject.send(providers)
        }
    }

    func persistSelectedRunnableModelID(_ modelID: String?) {
        if let modelID {
            UserDefaults.standard.set(modelID, forKey: Self.selectedRunnableModelStorageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedRunnableModelStorageKey)
        }
    }

    public func reloadProviders() {
        logger.info("正在重新加载提供商配置...")
        let currentSelectedID = selectedModelSubject.value?.id

        self.providers = ConfigLoader.loadProviders()
        self.reconcileStoredModelOrder()

        let allRunnable = activatedRunnableModels
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
        ConfigLoader.deleteProvider(provider)
        reloadProviders()
    }

    public func setSelectedModel(_ model: RunnableModel?) {
        guard selectedModelSubject.value?.id != model?.id else { return }
        selectedModelSubject.send(model)
        persistSelectedRunnableModelID(model?.id)
        logger.info("已将模型切换为: \(model?.model.displayName ?? "无")")
        AppLog.userOperation(
            category: "模型",
            action: "切换模型",
            payload: [
                "provider": model?.provider.name ?? "无",
                "model": model?.model.displayName ?? "无"
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
