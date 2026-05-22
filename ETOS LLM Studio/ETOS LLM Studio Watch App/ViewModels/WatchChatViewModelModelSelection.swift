// ============================================================================
// WatchChatViewModelModelSelection.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS ChatViewModel 中各类专用模型的选项计算、选择写回
// 与持久化标识同步。
// ============================================================================

import Foundation
import Shared

extension ChatViewModel {
    var embeddingModelOptions: [RunnableModel] {
        configuredModels.filter { $0.model.kind == .embedding }
    }

    var titleGenerationModelOptions: [RunnableModel] {
        activatedChatModels
    }

    var dailyPulseModelOptions: [RunnableModel] {
        activatedChatModels
    }

    var conversationSummaryModelOptions: [RunnableModel] {
        activatedChatModels
    }

    var reasoningSummaryModelOptions: [RunnableModel] {
        activatedChatModels
    }

    var ocrModelOptions: [RunnableModel] {
        chatService.activatedOCRModels
    }

    private func persistSpecializedModelIdentifier(_ identifier: String, for key: AppConfigKey) {
        AppConfigStore.persistSynchronously(.text(identifier), for: key)
    }

    func toggleMathRendering(for messageID: UUID) {
        if mathRenderOverrides.contains(messageID) {
            mathRenderOverrides.remove(messageID)
        } else {
            mathRenderOverrides.insert(messageID)
        }
    }

    func isMathRenderingEnabled(for messageID: UUID) -> Bool {
        guard enableAdvancedRenderer else { return false }
        return mathRenderOverrides.contains(messageID)
    }

    func setSelectedSpeechModel(_ model: RunnableModel?) {
        selectedSpeechModel = model
        let newIdentifier = model?.id ?? ""
        persistSpecializedModelIdentifier(newIdentifier, for: .speechModelIdentifier)
        if speechModelIdentifier != newIdentifier {
            speechModelIdentifier = newIdentifier
        }
    }

    func setSelectedTTSModel(_ model: RunnableModel?) {
        selectedTTSModel = model
        let newIdentifier = model?.id ?? ""
        persistSpecializedModelIdentifier(newIdentifier, for: .ttsModelIdentifier)
        if ttsModelIdentifier != newIdentifier {
            ttsModelIdentifier = newIdentifier
        }
        ttsManager.updateSelectedModel(model)
    }

    func setSelectedEmbeddingModel(_ model: RunnableModel?) {
        selectedEmbeddingModel = model
        let newIdentifier = model?.id ?? ""
        persistSpecializedModelIdentifier(newIdentifier, for: .memoryEmbeddingModelIdentifier)
        if memoryEmbeddingModelIdentifier != newIdentifier {
            memoryEmbeddingModelIdentifier = newIdentifier
        }
    }

    func setSelectedTitleGenerationModel(_ model: RunnableModel?) {
        selectedTitleGenerationModel = model
        let newIdentifier = model?.id ?? ""
        persistSpecializedModelIdentifier(newIdentifier, for: .titleGenerationModelIdentifier)
        if titleGenerationModelIdentifier != newIdentifier {
            titleGenerationModelIdentifier = newIdentifier
        }
    }

    func setSelectedDailyPulseModel(_ model: RunnableModel?) {
        selectedDailyPulseModel = model
        let newIdentifier = model?.id ?? ""
        persistSpecializedModelIdentifier(newIdentifier, for: .dailyPulseModelIdentifier)
        if dailyPulseModelIdentifier != newIdentifier {
            dailyPulseModelIdentifier = newIdentifier
        }
    }

    func setSelectedConversationSummaryModel(_ model: RunnableModel?) {
        selectedConversationSummaryModel = model
        let newIdentifier = model?.id ?? ""
        persistSpecializedModelIdentifier(newIdentifier, for: .conversationSummaryModelIdentifier)
        if conversationSummaryModelIdentifier != newIdentifier {
            conversationSummaryModelIdentifier = newIdentifier
        }
    }

    func setSelectedReasoningSummaryModel(_ model: RunnableModel?) {
        selectedReasoningSummaryModel = model
        let newIdentifier = model?.id ?? ""
        persistSpecializedModelIdentifier(newIdentifier, for: .reasoningSummaryModelIdentifier)
        if reasoningSummaryModelIdentifier != newIdentifier {
            reasoningSummaryModelIdentifier = newIdentifier
        }
    }

    func setSelectedOCRModel(_ model: RunnableModel?) {
        selectedOCRModel = model
        let newIdentifier = model?.id ?? ""
        persistSpecializedModelIdentifier(newIdentifier, for: .ocrModelIdentifier)
        if ocrModelIdentifier != newIdentifier {
            ocrModelIdentifier = newIdentifier
        }
    }

    func syncSpeechModelSelection() {
        if let match = speechModels.first(where: { $0.id == speechModelIdentifier }) {
            if selectedSpeechModel?.id != match.id {
                selectedSpeechModel = match
            }
            return
        }
        guard !speechModelIdentifier.isEmpty else {
            selectedSpeechModel = nil
            return
        }
        guard !speechModels.isEmpty else { return }
        selectedSpeechModel = nil
        persistSpecializedModelIdentifier("", for: .speechModelIdentifier)
        speechModelIdentifier = ""
    }

    func syncTTSModelSelection() {
        if let match = ttsModels.first(where: { $0.id == ttsModelIdentifier }) {
            if selectedTTSModel?.id != match.id {
                selectedTTSModel = match
            }
            ttsManager.updateSelectedModel(match)
            return
        }
        guard !ttsModelIdentifier.isEmpty else {
            selectedTTSModel = nil
            ttsManager.updateSelectedModel(nil)
            return
        }
        guard !ttsModels.isEmpty else { return }
        selectedTTSModel = nil
        persistSpecializedModelIdentifier("", for: .ttsModelIdentifier)
        ttsModelIdentifier = ""
        ttsManager.updateSelectedModel(nil)
    }

    func syncEmbeddingModelSelection() {
        if let match = embeddingModelOptions.first(where: { $0.id == memoryEmbeddingModelIdentifier }) {
            if selectedEmbeddingModel?.id != match.id {
                selectedEmbeddingModel = match
            }
            return
        }
        guard !memoryEmbeddingModelIdentifier.isEmpty else {
            selectedEmbeddingModel = nil
            return
        }
        guard !configuredModels.isEmpty else { return }
        selectedEmbeddingModel = nil
        persistSpecializedModelIdentifier("", for: .memoryEmbeddingModelIdentifier)
        memoryEmbeddingModelIdentifier = ""
    }

    func syncTitleGenerationModelSelection() {
        if let match = titleGenerationModelOptions.first(where: { $0.id == titleGenerationModelIdentifier }) {
            if selectedTitleGenerationModel?.id != match.id {
                selectedTitleGenerationModel = match
            }
            return
        }
        guard !titleGenerationModelIdentifier.isEmpty else {
            selectedTitleGenerationModel = nil
            return
        }
        guard !titleGenerationModelOptions.isEmpty else { return }
        selectedTitleGenerationModel = nil
        persistSpecializedModelIdentifier("", for: .titleGenerationModelIdentifier)
        titleGenerationModelIdentifier = ""
    }

    func syncDailyPulseModelSelection() {
        if let match = dailyPulseModelOptions.first(where: { $0.id == dailyPulseModelIdentifier }) {
            if selectedDailyPulseModel?.id != match.id {
                selectedDailyPulseModel = match
            }
            return
        }
        guard !dailyPulseModelIdentifier.isEmpty else {
            selectedDailyPulseModel = nil
            return
        }
        guard !dailyPulseModelOptions.isEmpty else { return }
        selectedDailyPulseModel = nil
        persistSpecializedModelIdentifier("", for: .dailyPulseModelIdentifier)
        dailyPulseModelIdentifier = ""
    }

    func syncConversationSummaryModelSelection() {
        if let match = conversationSummaryModelOptions.first(where: { $0.id == conversationSummaryModelIdentifier }) {
            if selectedConversationSummaryModel?.id != match.id {
                selectedConversationSummaryModel = match
            }
            return
        }
        guard !conversationSummaryModelIdentifier.isEmpty else {
            selectedConversationSummaryModel = nil
            return
        }
        guard !conversationSummaryModelOptions.isEmpty else { return }
        selectedConversationSummaryModel = nil
        persistSpecializedModelIdentifier("", for: .conversationSummaryModelIdentifier)
        conversationSummaryModelIdentifier = ""
    }

    func syncReasoningSummaryModelSelection() {
        if let match = reasoningSummaryModelOptions.first(where: { $0.id == reasoningSummaryModelIdentifier }) {
            if selectedReasoningSummaryModel?.id != match.id {
                selectedReasoningSummaryModel = match
            }
            return
        }
        guard !reasoningSummaryModelIdentifier.isEmpty else {
            selectedReasoningSummaryModel = nil
            return
        }
        guard !reasoningSummaryModelOptions.isEmpty else { return }
        selectedReasoningSummaryModel = nil
        persistSpecializedModelIdentifier("", for: .reasoningSummaryModelIdentifier)
        reasoningSummaryModelIdentifier = ""
    }

    func syncOCRModelSelection() {
        guard !ocrModelIdentifier.isEmpty else {
            selectedOCRModel = nil
            return
        }
        guard !ocrModelOptions.isEmpty else {
            selectedOCRModel = nil
            persistSpecializedModelIdentifier("", for: .ocrModelIdentifier)
            ocrModelIdentifier = ""
            return
        }
        if let match = ocrModelOptions.first(where: { $0.id == ocrModelIdentifier }) {
            if selectedOCRModel?.id != match.id {
                selectedOCRModel = match
            }
            return
        }
        selectedOCRModel = nil
        persistSpecializedModelIdentifier("", for: .ocrModelIdentifier)
        ocrModelIdentifier = ""
    }
}
