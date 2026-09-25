// ============================================================================
// GuideModelRouter.swift
// ============================================================================
// ETOS LLM Studio
//
// 路线切换是显式设置；用户模型失效时绝不静默消耗内置免费额度。
// ============================================================================

import Foundation
import Combine

/// 在提供商变化时统一准备索引与分组，长模型列表不在手表渲染过程中重新整理。
public struct GuideModelOptions {
    public let models: [RunnableModel]
    public let modelIDsAllowingNone: [String]
    public let modelsByID: [String: RunnableModel]
    public let providerGroups: [RunnableModelProviderGroup]
    public let groupsByProviderID: [UUID: RunnableModelProviderGroup]

    public init(providers: [Provider]) {
        models = providers.flatMap { provider -> [RunnableModel] in
            guard !LocalModelProviderBridge.isLocalProvider(provider) else { return [] }
            return provider.models.compactMap { model in
                guard model.isActivated,
                      model.isConversationModel,
                      model.isChatModel,
                      model.supportsToolCalling else { return nil }
                return RunnableModel(provider: provider, model: model)
            }
        }
        modelIDsAllowingNone = [""] + models.map(\.id)
        modelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        providerGroups = RunnableModelGrouping.groups(models: models, providerOrder: providers)
        groupsByProviderID = Dictionary(uniqueKeysWithValues: providerGroups.map { ($0.id, $0) })
    }
}

@MainActor
public final class GuideModelRouter: ObservableObject {
    private let appConfig: AppConfigStore
    private let chatService: ChatService
    private let builtInClient: any GuideCompletionClient
    private var cancellables = Set<AnyCancellable>()

    @Published public private(set) var modelOptions = GuideModelOptions(providers: [])

    public var availableUserModels: [RunnableModel] { modelOptions.models }

    public init(
        appConfig: AppConfigStore? = nil,
        chatService: ChatService = .shared,
        builtInClient: any GuideCompletionClient = GuideBuiltInCompletionClient()
    ) {
        self.appConfig = appConfig ?? .shared
        self.chatService = chatService
        self.builtInClient = builtInClient
        observeRunnableModels()
    }

    public var route: GuideRoute {
        get { GuideRoute(rawValue: appConfig.guidePreferredRoute) ?? .builtIn }
        set { appConfig.guidePreferredRoute = newValue.rawValue }
    }

    public var selectedUserModel: RunnableModel? {
        modelOptions.modelsByID[appConfig.guidePreferredModelIdentifier]
    }

    public func selectUserModel(_ model: RunnableModel) {
        guard modelOptions.modelsByID[model.id] != nil else { return }
        appConfig.guidePreferredModelIdentifier = model.id
        route = .userModel
    }

    public func useBuiltIn() {
        route = .builtIn
    }

    public func resolvedClient() throws -> (client: any GuideCompletionClient, includesClientSystemPrompt: Bool) {
        switch route {
        case .builtIn:
            return (builtInClient, false)
        case .userModel:
            guard let selectedUserModel else { throw GuideError.missingRunnableModel }
            return (GuideUserModelCompletionClient(chatService: chatService, runnableModel: selectedUserModel), true)
        }
    }

    private func observeRunnableModels() {
        let processingQueue = DispatchQueue(label: "com.ericterminal.etos.guide-model-options", qos: .userInitiated)
        chatService.providersSubject
            .receive(on: processingQueue)
            .map(GuideModelOptions.init(providers:))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] options in
                self?.modelOptions = options
            }
            .store(in: &cancellables)
    }
}
