// ============================================================================
// GuideModelRouter.swift
// ============================================================================
// ETOS LLM Studio
//
// 路线切换是显式设置；用户模型失效时绝不静默消耗内置免费额度。
// ============================================================================

import Foundation
import Combine

@MainActor
public final class GuideModelRouter: ObservableObject {
    private let appConfig: AppConfigStore
    private let chatService: ChatService
    private let builtInClient: any GuideCompletionClient
    private var availableUserModelByID: [String: RunnableModel] = [:]
    private var cancellables = Set<AnyCancellable>()

    @Published public private(set) var availableUserModels: [RunnableModel] = []

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
        availableUserModelByID[appConfig.guidePreferredModelIdentifier]
    }

    public func selectUserModel(_ model: RunnableModel) {
        guard availableUserModelByID[model.id] != nil else { return }
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
            .map(Self.makeEligibleUserModels)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] models in
                self?.availableUserModels = models
                self?.availableUserModelByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            }
            .store(in: &cancellables)
    }

    private nonisolated static func makeEligibleUserModels(from providers: [Provider]) -> [RunnableModel] {
        providers.flatMap { provider -> [RunnableModel] in
            guard !LocalModelProviderBridge.isLocalProvider(provider) else { return [] }
            return provider.models.compactMap { model in
                guard model.isActivated,
                      model.isConversationModel,
                      model.isChatModel,
                      model.supportsToolCalling else { return nil }
                return RunnableModel(provider: provider, model: model)
            }
        }
    }
}
