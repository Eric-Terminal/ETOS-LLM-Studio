import Combine
import SwiftUI

/// 仅订阅模型配置。聊天正文、会话标题和草稿均不进入起步卡或其页面快照。
@MainActor
public final class GuideSetupPresentation: ObservableObject {
    public static let shared = GuideSetupPresentation()
    @Published public private(set) var state: GuideModelSetupState?

    private init() {
        let service = ChatService.shared
        service.providersSubject.combineLatest(service.selectedModelSubject)
            .receive(on: DispatchQueue(label: "studio.etos.guide.setup", qos: .userInitiated))
            .map { @Sendable in GuideModelSetupStateResolver.resolve(providers: $0.0, selectedModel: $0.1) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .map(Optional.some)
            .assign(to: &$state)
    }

    public static func descriptor(id: GuidePageID = "chat-home") -> GuidePageDescriptor {
        GuidePageDescriptor(id: id, title: NSLocalizedString("开始使用 ETOS LLM Studio", value: "Get Started with ETOS LLM Studio", comment: "起步卡标题"),
            documents: [GuideDocumentReference(id: "getting-started-guide", title: "Getting Started"),
                        GuideDocumentReference(id: "app-features-tour", title: "App Features")])
    }

    public static var setupPrompt: String {
        NSLocalizedString("我是新手，请带我一步步配好模型开始聊天", value: "I'm new here. Please walk me through setting up a model for my first chat.", comment: "首次配置提问")
    }

    public static func snapshot() -> GuidePageSnapshot {
        GuidePageSnapshot(fields: ["setup_state": GuideSnapshotField(
            label: NSLocalizedString("模型配置状态", value: "Model Setup", comment: "只读配置状态"),
            value: .string(shared.state?.rawValue ?? ""), access: .readOnly)])
    }

    public static func hint(for state: GuideModelSetupState) -> String {
        switch state {
        case .needsProvider: NSLocalizedString("先添加提供商，填入它给你的接口地址。", value: "Add a provider and enter the API address it gave you.", comment: "缺少提供商")
        case .needsCredential: NSLocalizedString("提供商已经添加好了，再填入它的 API Key 就能继续。", value: "Your provider is set up. Enter its API key to continue.", comment: "缺少密钥")
        case .needsModel: NSLocalizedString("接下来可以获取模型列表，或手动添加一个聊天模型。", value: "Fetch the model list or add a chat model by name.", comment: "缺少模型")
        case .needsActivationOrSelection: NSLocalizedString("在模型管理中启用一个聊天模型，再选它作为当前模型。", value: "Enable a chat model in Model Management, then select it for this chat.", comment: "模型未启用或选中")
        case .ready: NSLocalizedString("模型已就绪，可以开始聊天了。", value: "Your model is ready for a chat.", comment: "模型就绪")
        }
    }
}

/// 单独打开助手时也有可读的页面；已声明的设置页始终优先。
public struct GuideConversationFallbackContext: ViewModifier {
    @ObservedObject private var coordinator = GuideContextCoordinator.shared
    public init() {}

    public func body(content: Content) -> some View {
        content.guidePageContext(descriptor: GuideSetupPresentation.descriptor(), isFallback: true,
            isActive: coordinator.activePage == nil || coordinator.activePage?.id == "chat-home",
            snapshot: { GuideSetupPresentation.snapshot() })
    }
}

/// 先注册临时页面，再等历史恢复结束，避免第一问读到来源页或覆盖已恢复的对话。
public struct GuideOnboardingContext: ViewModifier {
    @ObservedObject private var controller: GuideConversationController
    @ObservedObject private var coordinator = GuideContextCoordinator.shared
    @State private var handledPrompt = false
    private let pageID: GuidePageID
    private let prompt: String

    public init(controller: GuideConversationController, pageID: GuidePageID, prompt: String) {
        self.controller = controller
        self.pageID = pageID
        self.prompt = prompt
    }

    public func body(content: Content) -> some View {
        content
            .guidePageContext(descriptor: GuideSetupPresentation.descriptor(id: pageID),
                              snapshot: { GuideSetupPresentation.snapshot() })
            .task(id: coordinator.activePage?.id) {
                guard coordinator.activePage?.id == pageID, !handledPrompt else { return }
                await controller.restoreHistory()
                guard !Task.isCancelled, coordinator.activePage?.id == pageID, !handledPrompt else { return }
                handledPrompt = true
                if controller.messages.isEmpty { controller.send(prompt) }
            }
    }
}

@MainActor
private final class GuideQuestionList: ObservableObject {
    @Published private(set) var prompts: [String] = []

    init() {
        GuideContextCoordinator.shared.$activePage
            .combineLatest(GuideSetupPresentation.shared.$state.compactMap { $0 }, AppConfigStore.shared.$appLanguage)
            .map { ($0.0 ?? GuideSetupPresentation.descriptor(), $0.1) }
            .receive(on: DispatchQueue(label: "studio.etos.guide.suggestions", qos: .userInitiated))
            .map { @Sendable in GuideSuggestedPromptsResolver.resolve(page: $0.0, setupState: $0.1) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$prompts)
    }
}

/// 页面切换和配置变更才更新推荐问题，流式输出不触发重新计算。
public struct GuideSuggestedQuestions: View {
    @StateObject private var suggestions = GuideQuestionList()
    @ObservedObject private var controller: GuideConversationController
    public init(controller: GuideConversationController) {
        self.controller = controller
    }

    public var body: some View {
        ForEach(suggestions.prompts, id: \.self) { prompt in
            Button { controller.send(prompt) } label: {
                Text(prompt).lineLimit(2).minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(controller.isResponding || controller.isRestoringHistory)
        }
    }
}
