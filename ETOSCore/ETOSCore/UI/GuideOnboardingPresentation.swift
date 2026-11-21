import Combine
import SwiftUI

/// 起步引导卡支持的内置免费向导提问主题，供三端零配置欢迎卡共享。
public enum GuideOnboardingTopic: String, Identifiable, Sendable {
    case setup
    case tour

    public var id: Self { self }

    @MainActor public var prompt: String {
        switch self {
        case .setup:
            GuideSetupPresentation.setupPrompt
        case .tour:
            GuideSetupPresentation.tourPrompt
        }
    }
}

/// 仅订阅模型配置。聊天正文、会话标题和草稿均不进入起步卡或其页面快照。
@MainActor
public final class GuideSetupPresentation: ObservableObject {
    public static let shared = GuideSetupPresentation()
    public static let totalSetupSteps = 4

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

    public static var tourPrompt: String {
        NSLocalizedString("这个软件有哪些实用功能？", value: "What can I do with this app?", comment: "功能导览提问")
    }

    public static var welcomeTitle: String {
        NSLocalizedString("欢迎使用 ETOS LLM Studio", value: "Welcome to ETOS LLM Studio", comment: "起步卡欢迎主标题")
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

    /// 将当前未就绪阶段映射为 1...4 步，供进度点与半途徽章展示。
    public static func stepNumber(for state: GuideModelSetupState) -> Int? {
        switch state {
        case .needsProvider: 1
        case .needsCredential: 2
        case .needsModel: 3
        case .needsActivationOrSelection: 4
        case .ready: nil
        }
    }

    /// 首次打开尚未添加提供商时不渲染催促感进度条；已推进至少一步后再给予正向进度反馈。
    public static func hasPartialProgress(for state: GuideModelSetupState) -> Bool {
        switch state {
        case .needsCredential, .needsModel, .needsActivationOrSelection:
            true
        case .needsProvider, .ready:
            false
        }
    }

    public static func stageShortTitle(for state: GuideModelSetupState) -> String? {
        switch state {
        case .needsCredential:
            NSLocalizedString("待填写密钥", value: "API Key Needed", comment: "起步卡阶段短标签：待填写密钥")
        case .needsModel:
            NSLocalizedString("待添加模型", value: "Add a Model", comment: "起步卡阶段短标签：待添加模型")
        case .needsActivationOrSelection:
            NSLocalizedString("待启用并选中", value: "Select a Model", comment: "起步卡阶段短标签：待启用模型")
        case .needsProvider, .ready:
            nil
        }
    }

    public static func progressBadgeTitle(for state: GuideModelSetupState) -> String? {
        guard let step = stepNumber(for: state),
              let shortTitle = stageShortTitle(for: state) else {
            return nil
        }
        return String(
            format: NSLocalizedString("进度 %d/%d · %@", value: "Step %d/%d · %@", comment: "起步卡半途配置进度胶囊"),
            step,
            totalSetupSteps,
            shortTitle
        )
    }

    public static func welcomeSubtitle(for state: GuideModelSetupState) -> String {
        switch state {
        case .needsProvider:
            NSLocalizedString(
                "连接模型提供商或本地模型即可开始对话。不知从何下手？点下方按钮，内置免费助手会一步步带你配好。",
                value: "Connect a provider or local model to start chatting. Not sure where to begin? The free built-in guide can walk you through every step.",
                comment: "起步卡首次打开温和欢迎副标题"
            )
        case .needsCredential:
            NSLocalizedString(
                "提供商已添加好，接下来只需填入对应的 API Key 就能继续。",
                value: "Your provider is saved—just enter its API key to continue.",
                comment: "起步卡待填密钥温和说明"
            )
        case .needsModel:
            NSLocalizedString(
                "连接信息已备好，拉取模型列表或手动添加一个聊天模型即可。",
                value: "Connection details are set. Fetch the model list or add a chat model next.",
                comment: "起步卡待添模型温和说明"
            )
        case .needsActivationOrSelection:
            NSLocalizedString(
                "只差最后一步：去模型管理启用一个聊天模型，并将它选为当前对话模型。",
                value: "Almost ready—enable a chat model in Model Management and select it for this chat.",
                comment: "起步卡待启用模型温和说明"
            )
        case .ready:
            hint(for: .ready)
        }
    }

    /// watchOS 首屏宽度有限，首次打开使用精炼欢迎语，推进后复用短句提示。
    public static func watchWelcomeSubtitle(for state: GuideModelSetupState) -> String {
        switch state {
        case .needsProvider:
            NSLocalizedString(
                "连接提供商即可开聊，也可让免费助手一步步带你配好。",
                value: "Connect a provider to chat, or let the free guide set it up with you.",
                comment: "手表起步卡首次打开精炼说明"
            )
        case .needsCredential, .needsModel, .needsActivationOrSelection, .ready:
            hint(for: state)
        }
    }

    public static func manualSetupSubtitle(for state: GuideModelSetupState) -> String {
        if state == .needsActivationOrSelection {
            return NSLocalizedString(
                "启用已添加的模型并设为当前对话模型",
                value: "Enable an added model and select it for chat",
                comment: "起步卡第4步手动启用模型副标题"
            )
        }
        return NSLocalizedString(
            "手动添加提供商、接口地址与模型",
            value: "Add providers, API addresses, and models yourself",
            comment: "起步卡手动配置副标题"
        )
    }
}

/// 起步欢迎卡头部微光图标徽章；开启降低透明度时退化为实色高对比底托。
public struct GuideOnboardingHeroBadge: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let size: CGFloat
    private let iconSize: CGFloat
    private let cornerRadius: CGFloat

    public init(size: CGFloat = 44, iconSize: CGFloat = 20, cornerRadius: CGFloat = 13) {
        self.size = size
        self.iconSize = iconSize
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if reduceTransparency {
                shape.fill(Color.blue)
            } else {
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.92),
                                Color.blue,
                                Color.indigo.opacity(0.95)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.blue.opacity(0.24), radius: 8, x: 0, y: 4)
            }
            Image(systemName: "sparkles")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay {
            shape.strokeBorder(Color.white.opacity(reduceTransparency ? 0.45 : 0.28), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

/// 当用户已完成部分配置时展示的 4 段微光进度胶囊，给予明确的正向阶段反馈。
public struct GuideSetupProgressBadge: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    private let state: GuideModelSetupState
    private let compact: Bool

    public init(state: GuideModelSetupState, compact: Bool = false) {
        self.state = state
        self.compact = compact
    }

    public var body: some View {
        if let currentStep = GuideSetupPresentation.stepNumber(for: state),
           let title = GuideSetupPresentation.progressBadgeTitle(for: state) {
            HStack(spacing: compact ? 5 : 6) {
                HStack(spacing: 3) {
                    ForEach(1...GuideSetupPresentation.totalSetupSteps, id: \.self) { index in
                        Capsule()
                            .fill(stepColor(for: index, currentStep: currentStep))
                            .frame(width: index == currentStep ? (compact ? 10 : 12) : (compact ? 4 : 5), height: compact ? 4 : 5)
                    }
                }
                .accessibilityHidden(true)

                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.cyan : Color.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, compact ? 8 : 9)
            .padding(.vertical, compact ? 3 : 4)
            .background {
                Capsule()
                    .fill(Color.blue.opacity(reduceTransparency ? (colorScheme == .dark ? 0.28 : 0.16) : (colorScheme == .dark ? 0.18 : 0.10)))
            }
            .overlay {
                Capsule()
                    .strokeBorder(Color.blue.opacity(reduceTransparency ? 0.45 : 0.22), lineWidth: 0.5)
            }
        }
    }

    private func stepColor(for index: Int, currentStep: Int) -> Color {
        if index < currentStep {
            return colorScheme == .dark ? Color.cyan.opacity(0.9) : Color.blue.opacity(0.85)
        } else if index == currentStep {
            return colorScheme == .dark ? Color.cyan : Color.blue
        } else {
            return Color.primary.opacity(0.18)
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
