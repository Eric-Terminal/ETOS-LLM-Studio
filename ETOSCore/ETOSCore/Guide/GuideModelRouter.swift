// ============================================================================
// GuideModelRouter.swift
// ============================================================================
// ETOS LLM Studio
//
// 路线切换是显式设置；用户模型失效时绝不静默消耗内置免费额度。
// ============================================================================

import Foundation

@MainActor
public final class GuideModelRouter {
    private let appConfig: AppConfigStore
    private let chatService: ChatService
    private let builtInClient: any GuideCompletionClient

    public init(
        appConfig: AppConfigStore? = nil,
        chatService: ChatService = .shared,
        builtInClient: any GuideCompletionClient = GuideBuiltInCompletionClient()
    ) {
        self.appConfig = appConfig ?? .shared
        self.chatService = chatService
        self.builtInClient = builtInClient
    }

    public var route: GuideRoute {
        get { GuideRoute(rawValue: appConfig.guidePreferredRoute) ?? .builtIn }
        set { appConfig.guidePreferredRoute = newValue.rawValue }
    }

    public var availableUserModels: [RunnableModel] {
        chatService.activatedChatModels.filter {
            $0.model.supportsToolCalling && !LocalModelProviderBridge.isLocalRunnableModel($0)
        }
    }

    public var selectedUserModel: RunnableModel? {
        availableUserModels.first { $0.id == appConfig.guidePreferredModelIdentifier }
    }

    public func selectUserModel(_ model: RunnableModel) {
        guard availableUserModels.contains(where: { $0.id == model.id }) else { return }
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
}
