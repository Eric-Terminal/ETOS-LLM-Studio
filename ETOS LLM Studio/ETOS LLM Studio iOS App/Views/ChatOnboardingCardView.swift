import ETOSCore
import SwiftUI

struct OpenChatOnboardingGuideAction {
    let router: GuideModelRouter
    let selection: Binding<ChatOnboardingTopic?>

    @MainActor func callAsFunction(_ topic: ChatOnboardingTopic) {
        router.useBuiltIn()
        selection.wrappedValue = topic
    }
}

extension EnvironmentValues {
    @Entry var openChatOnboardingGuide: OpenChatOnboardingGuideAction? = nil
}

enum ChatOnboardingTopic: Identifiable {
    case setup, tour
    var id: Self { self }

    var prompt: String {
        switch self {
        case .setup: GuideSetupPresentation.setupPrompt
        case .tour: NSLocalizedString("这个软件有哪些实用功能？", value: "What can I do with this app?", comment: "功能导览提问")
        }
    }
}

struct ChatOnboardingCardView: View {
    @Environment(\.openChatOnboardingGuide) private var openGuide
    @ObservedObject private var setup = GuideSetupPresentation.shared

    var body: some View {
        if let state = setup.state, state != .ready {
            ViewThatFits(in: .vertical) {
                card(state).fixedSize(horizontal: false, vertical: true)
                ScrollView { card(state) }
            }
            .frame(maxWidth: 360)
            .padding()
        }
    }

    private func card(_ state: GuideModelSetupState) -> some View {
        VStack(alignment: .leading) {
            Label {
                Text(NSLocalizedString("开始使用 ETOS LLM Studio", value: "Get Started with ETOS LLM Studio", comment: "起步卡标题"))
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(.tint)
            }
            .font(.headline)
            Text(GuideSetupPresentation.hint(for: state))
                .font(.footnote).foregroundStyle(.secondary)
            Button { openGuide?(.setup) } label: {
                Label(NSLocalizedString("让免费助手带我配好", value: "Set Up with the Free Guide", comment: "助手配置入口"), systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button { GuideNavigationCoordinator.shared.request(.providerManagement) } label: {
                Label(NSLocalizedString("前往模型管理", value: "Open Model Management", comment: "手动配置入口"), systemImage: "shippingbox")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Divider()
            Button {
                GuideNavigationCoordinator.shared.request(.dataImport)
            } label: {
                Label(NSLocalizedString("导入已有配置或角色卡", value: "Import a Configuration or Character Card", comment: "起步卡导入入口"), systemImage: "square.and.arrow.down")
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            Button { openGuide?(.tour) } label: {
                Label(NSLocalizedString("先看看软件有哪些功能", value: "Explore App Features", comment: "功能导览入口"), systemImage: "compass.drawing")
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
