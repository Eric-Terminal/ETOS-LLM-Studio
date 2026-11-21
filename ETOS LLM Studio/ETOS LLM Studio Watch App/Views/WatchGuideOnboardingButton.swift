// ============================================================================
// WatchGuideOnboardingButton.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// watchOS 零配置欢迎状态卡片与独立操作行；严格遵循每行单一交互控件的防粘连规范。
// ============================================================================

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

/// 主聊天首屏不可点击的欢迎与阶段进度状态卡片行。
struct WatchChatOnboardingStatusRow: View {
    let state: GuideModelSetupState
    var isLiquidGlassEnabled: Bool = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                GuideOnboardingHeroBadge(size: 26, iconSize: 13, cornerRadius: 8)
                Text(GuideSetupPresentation.welcomeTitle)
                    .etFont(.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if GuideSetupPresentation.hasPartialProgress(for: state) {
                GuideSetupProgressBadge(state: state, compact: true)
            }

            Text(GuideSetupPresentation.watchWelcomeSubtitle(for: state))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if reduceTransparency {
                cardShape.fill(Color.white.opacity(0.14))
            } else if #available(watchOS 26.0, *), isLiquidGlassEnabled {
                cardShape
                    .fill(Color.white.opacity(0.08))
                    .glassEffect(.regular, in: cardShape)
            } else {
                cardShape.fill(Color.white.opacity(0.10))
            }
        }
        .overlay {
            cardShape.strokeBorder(Color.white.opacity(reduceTransparency ? 0.28 : 0.16), lineWidth: 0.5)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
    }
}

/// 主聊天首屏独立的「前往模型管理」次级操作行。
struct WatchChatOnboardingModelManagementRow: View {
    let state: GuideModelSetupState

    var body: some View {
        let isReadyToActivate = state == .needsActivationOrSelection
        let tint: Color = isReadyToActivate ? .green : .blue
        let iconName = isReadyToActivate ? "checkmark.circle.fill" : "slider.horizontal.3"

        Button {
            GuideNavigationCoordinator.shared.request(.providerManagement)
        } label: {
            HStack(spacing: 9) {
                WatchOnboardingRowIcon(systemName: iconName, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("前往模型管理", value: "Open Model Management", comment: "手表手动配置入口"))
                        .etFont(.footnote)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    if isReadyToActivate {
                        Text(GuideSetupPresentation.manualSetupSubtitle(for: state))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct WatchGuideOnboardingButton: View {
    enum Style {
        case standard
        case primaryChatAction
        case secondaryTourAction
    }

    @EnvironmentObject private var controller: GuideConversationController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var presented = false

    private let style: Style

    init(style: Style = .standard) {
        self.style = style
    }

    private var topic: GuideOnboardingTopic {
        switch style {
        case .standard, .primaryChatAction:
            .setup
        case .secondaryTourAction:
            .tour
        }
    }

    var body: some View {
        Button {
            controller.router.useBuiltIn()
            presented = true
            WatchGuideSheetNavigation.shared.close = { presented = false }
        } label: {
            buttonLabel
        }
        .listRowBackground(rowBackground)
        .sheet(isPresented: $presented, onDismiss: { WatchGuideSheetNavigation.shared.didDismiss() }) {
            NavigationStack {
                WatchGuideConversationView(controller: controller) { presented = false }
                    .modifier(GuideOnboardingContext(controller: controller, pageID: "watch-onboarding", prompt: topic.prompt))
            }
        }
    }

    @ViewBuilder
    private var buttonLabel: some View {
        switch style {
        case .standard:
            Label {
                Text(NSLocalizedString("免费助手引导配置", value: "Set Up with the Free Guide", comment: "手表起步入口"))
            } icon: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.cyan)
            }
        case .primaryChatAction:
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                Text(NSLocalizedString("免费助手引导配置", value: "Set Up with the Free Guide", comment: "手表起步入口"))
                    .etFont(.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
        case .secondaryTourAction:
            HStack(spacing: 9) {
                WatchOnboardingRowIcon(systemName: "compass.drawing", tint: .teal)
                Text(NSLocalizedString("先逛逛软件有哪些功能", value: "Explore App Features First", comment: "起步卡功能导览标题"))
                    .etFont(.footnote)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if style == .primaryChatAction {
            let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
            if reduceTransparency {
                shape.fill(Color.blue)
            } else {
                shape
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.9), Color.blue, Color.indigo.opacity(0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        shape.strokeBorder(Color.white.opacity(0.26), lineWidth: 0.5)
                    }
            }
        }
    }
}

private struct WatchOnboardingRowIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.20))
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
