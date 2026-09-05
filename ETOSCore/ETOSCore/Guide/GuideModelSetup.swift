// ============================================================================
// GuideModelSetup.swift
// ============================================================================
// ETOS LLM Studio
//
// 首次模型配置由真实可运行状态驱动；草稿（尤其凭据）只存在于内存。
// ============================================================================

import Foundation
import Combine

public enum GuideModelSetupChoice: String, CaseIterable, Identifiable, Sendable {
    case cloud
    case custom
    case local
    case importConfiguration

    public var id: String { rawValue }
}

public struct GuideProviderTemplate: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let apiFormat: String

    public init(id: String, name: String, baseURL: String, apiFormat: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiFormat = apiFormat
    }

    public static let cloudTemplates = [
        GuideProviderTemplate(
            id: "openai",
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            apiFormat: "openai-compatible"
        ),
        GuideProviderTemplate(
            id: "anthropic",
            name: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            apiFormat: "anthropic"
        ),
        GuideProviderTemplate(
            id: "gemini",
            name: "Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiFormat: "gemini"
        )
    ]
}

public enum GuideModelSetupStateResolver {
    public static func resolve(
        providers: [Provider],
        selectedModel: RunnableModel?
    ) -> GuideModelSetupState {
        let nonLocalProviders = providers.filter { !LocalModelProviderBridge.isLocalProvider($0) }
        let hasEnabledLocalProvider = providers.contains(where: LocalModelProviderBridge.isLocalProvider)
        guard !nonLocalProviders.isEmpty || hasEnabledLocalProvider else { return .needsProvider }

        let remoteHasCredentials = nonLocalProviders.contains { !$0.apiKeys.isEmpty }
        if !hasEnabledLocalProvider && !remoteHasCredentials {
            return .needsCredential
        }

        let chatModels = providers.flatMap { provider in
            provider.models.filter(\.isChatModel).map { RunnableModel(provider: provider, model: $0) }
        }
        guard !chatModels.isEmpty else { return .needsModel }

        let activated = chatModels.filter { $0.model.isActivated }
        guard !activated.isEmpty,
              let selectedModel,
              activated.contains(where: { $0.id == selectedModel.id }) else {
            return .needsActivationOrSelection
        }
        return .ready
    }

    public static func resolve(chatService: ChatService = .shared) -> GuideModelSetupState {
        resolve(
            providers: chatService.providersSubject.value,
            selectedModel: chatService.selectedModelSubject.value
        )
    }
}

public enum GuideModelSetupValidation {
    public static func isValidRemoteBaseURL(_ value: String) -> Bool {
        guard let components = URLComponents(
            string: value.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            return false
        }
        return ["http", "https"].contains(components.scheme?.lowercased() ?? "")
            && !(components.host ?? "").isEmpty
    }
}

@MainActor
public final class GuideModelSetupDraft: ObservableObject {
    @Published public var choice: GuideModelSetupChoice?
    @Published public var providerName = "" { didSet { invalidateConnectivity() } }
    @Published public var baseURL = "" { didSet { invalidateConnectivity() } }
    @Published public var chatEndpointPath = Provider.defaultChatEndpointPath { didSet { invalidateConnectivity() } }
    @Published public var apiFormat = "openai-compatible" { didSet { invalidateConnectivity() } }
    @Published public var apiKey = "" { didSet { invalidateConnectivity() } }
    @Published public var modelName = "" { didSet { invalidateConnectivity() } }
    @Published public var modelDisplayName = "" { didSet { invalidateConnectivity() } }
    @Published public var enablesToolCalling = true { didSet { invalidateConnectivity() } }
    @Published public private(set) var fetchedModels: [Model] = []
    @Published public private(set) var isWorking = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var connectivityResult: ModelConnectivityTestResult?

    public let providerID = UUID()
    public let modelID = UUID()
    private let chatService: ChatService
    private var configurationRevision: UInt = 0
    private var verifiedRevision: UInt?

    public var isConnectivityVerified: Bool {
        connectivityResult?.status == .succeeded && verifiedRevision == configurationRevision
    }

    public init(chatService: ChatService = .shared) {
        self.chatService = chatService
    }

    public func applyTemplate(_ template: GuideProviderTemplate) {
        providerName = template.name
        baseURL = template.baseURL
        chatEndpointPath = Provider.defaultChatEndpointPath
        apiFormat = template.apiFormat
    }

    public func fetchAvailableModels() async {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            fetchedModels = try await chatService.fetchModels(for: provider(includeModel: false))
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func chooseFetchedModel(_ model: Model) {
        modelName = model.modelName
        modelDisplayName = model.displayName
        enablesToolCalling = model.supportsToolCalling
    }

    public func testConnectivity() async {
        guard !isWorking, !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        let provider = provider(includeModel: true)
        guard let model = provider.models.first else { return }
        let result = await chatService.testModelConnectivity(for: RunnableModel(provider: provider, model: model))
        connectivityResult = result
        if result.status == .succeeded {
            verifiedRevision = configurationRevision
        } else {
            verifiedRevision = nil
            lastError = result.errorMessage
        }
    }

    @discardableResult
    public func commit() throws -> RunnableModel {
        let provider = provider(includeModel: true)
        guard !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              GuideModelSetupValidation.isValidRemoteBaseURL(provider.baseURL),
              let model = provider.models.first,
              !model.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isConnectivityVerified else {
            throw GuideError.invalidToolArguments
        }
        let runnable = RunnableModel(provider: provider, model: model)
        guard ConfigLoader.saveProviderAndSelect(
            provider,
            selectedRunnableModelID: runnable.id
        ) else {
            throw NSError(
                domain: "GuideModelSetup",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("无法保存首次模型配置。", comment: "首次模型配置数据库写入失败")]
            )
        }
        chatService.reloadAppConfigBackedModelState()
        apiKey = ""
        return runnable
    }

    public func reset() {
        choice = nil
        providerName = ""
        baseURL = ""
        chatEndpointPath = Provider.defaultChatEndpointPath
        apiFormat = "openai-compatible"
        apiKey = ""
        modelName = ""
        modelDisplayName = ""
        enablesToolCalling = true
        fetchedModels = []
        connectivityResult = nil
        lastError = nil
    }

    private func invalidateConnectivity() {
        configurationRevision &+= 1
        verifiedRevision = nil
        connectivityResult = nil
    }

    private func provider(includeModel: Bool) -> Provider {
        let normalizedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let capabilities: [ModelCapability] = enablesToolCalling ? [.toolCalling] : []
        let models: [Model]
        if includeModel, !normalizedModelName.isEmpty {
            models = [Model(
                id: modelID,
                modelName: normalizedModelName,
                displayName: modelDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? normalizedModelName
                    : modelDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
                isActivated: true,
                kind: .chat,
                inputModalities: [.text],
                outputModalities: [.text],
                capabilities: capabilities
            )]
        } else {
            models = []
        }
        return Provider(
            id: providerID,
            name: providerName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            chatEndpointPath: chatEndpointPath,
            apiKeys: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [apiKey],
            apiFormat: apiFormat,
            models: models
        )
    }
}
