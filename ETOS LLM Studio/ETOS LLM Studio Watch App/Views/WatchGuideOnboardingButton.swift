import ETOSCore
import SwiftUI

/// 设置入口与聊天起步卡都可能呈现助手。等实际的 sheet 消失后才切换底层设置。
@MainActor
final class WatchGuideSheetNavigation {
    static let shared = WatchGuideSheetNavigation()
    var close: (() -> Void)?
    private var afterDismiss: (() -> Void)?

    func dismissThen(_ navigate: @escaping () -> Void) {
        if let close {
            afterDismiss = navigate
            close()
        } else {
            navigate()
        }
    }

    func didDismiss() {
        close = nil
        let navigate = afterDismiss
        afterDismiss = nil
        navigate?()
    }
}

struct WatchGuideOnboardingButton: View {
    @EnvironmentObject private var controller: GuideConversationController
    @State private var presented = false

    var body: some View {
        Button {
            controller.router.useBuiltIn()
            presented = true
            WatchGuideSheetNavigation.shared.close = { presented = false }
        } label: {
            Label(NSLocalizedString("免费助手引导配置", value: "Set Up with the Free Guide", comment: "手表起步入口"), systemImage: "sparkles")
        }
        .sheet(isPresented: $presented, onDismiss: { WatchGuideSheetNavigation.shared.didDismiss() }) {
            NavigationStack {
                WatchGuideConversationView(controller: controller) { presented = false }
                    .modifier(GuideOnboardingContext(controller: controller, pageID: "watch-onboarding", prompt: GuideSetupPresentation.setupPrompt))
            }
        }
    }
}
