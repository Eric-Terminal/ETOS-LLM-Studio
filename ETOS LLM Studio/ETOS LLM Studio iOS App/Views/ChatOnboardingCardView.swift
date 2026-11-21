// ============================================================================
// ChatOnboardingCardView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 主聊天空白态零配置欢迎引导卡：突出内置免费助手主入口，将进阶与导览操作收纳为内嵌分组导航行。
// ============================================================================

import ETOSCore
import SwiftUI
import UIKit

typealias ChatOnboardingTopic = GuideOnboardingTopic

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

struct ChatOnboardingCardView: View {
    var isLiquidGlassEnabled: Bool = true

    @Environment(\.openChatOnboardingGuide) private var openGuide
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var setup = GuideSetupPresentation.shared

    @ScaledMetric(relativeTo: .body) private var heroBadgeSize: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var rowIconBoxSize: CGFloat = 30

    private let cardShape = RoundedRectangle(cornerRadius: 26, style: .continuous)
    private let secondaryGroupShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        if let state = setup.state, state != .ready {
            ViewThatFits(in: .vertical) {
                cardBody(state)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical, showsIndicators: false) {
                    cardBody(state)
                }
            }
            .clipShape(cardShape)
            .background(cardBackground)
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.30 : 0.10),
                radius: 22,
                x: 0,
                y: 10
            )
            .frame(maxWidth: 380)
            .padding()
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 1.0), value: state)
        }
    }

    private func cardBody(_ state: GuideModelSetupState) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            headerSection(state)
            primaryGuideButton
            secondaryActionsGroup(state)
        }
        .padding(20)
    }

    @ViewBuilder
    private func headerSection(_ state: GuideModelSetupState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    GuideOnboardingHeroBadge(size: min(heroBadgeSize, 56), iconSize: 22, cornerRadius: 14)
                    if GuideSetupPresentation.hasPartialProgress(for: state) {
                        GuideSetupProgressBadge(state: state)
                    }
                    Text(GuideSetupPresentation.welcomeTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(alignment: .center, spacing: 13) {
                    GuideOnboardingHeroBadge(size: min(heroBadgeSize, 52), iconSize: 20, cornerRadius: 13)
                    VStack(alignment: .leading, spacing: 4) {
                        if GuideSetupPresentation.hasPartialProgress(for: state) {
                            GuideSetupProgressBadge(state: state)
                        }
                        Text(GuideSetupPresentation.welcomeTitle)
                            .font(GuideSetupPresentation.hasPartialProgress(for: state) ? .headline.weight(.semibold) : .title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text(GuideSetupPresentation.welcomeSubtitle(for: state))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var primaryGuideButton: some View {
        Button {
            openGuide?(.setup)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Text(NSLocalizedString("让免费助手带我配好", value: "Set Up with the Free Guide", comment: "助手配置入口"))
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }

    private func secondaryActionsGroup(_ state: GuideModelSetupState) -> some View {
        let clampedIconSize = min(rowIconBoxSize, 38)
        let dividerLeading = dynamicTypeSize.isAccessibilitySize ? 14 : (14 + clampedIconSize + 12)
        let isReadyToActivate = state == .needsActivationOrSelection

        return VStack(spacing: 0) {
            OnboardingSecondaryActionRow(
                icon: isReadyToActivate ? "checkmark.circle.fill" : "slider.horizontal.3",
                tint: isReadyToActivate ? .green : .blue,
                iconBoxSize: clampedIconSize,
                title: NSLocalizedString("自己去模型管理配置", value: "Configure in Model Management", comment: "起步卡手动配置标题"),
                subtitle: GuideSetupPresentation.manualSetupSubtitle(for: state)
            ) {
                GuideNavigationCoordinator.shared.request(.providerManagement)
            }

            Divider()
                .padding(.leading, dividerLeading)

            OnboardingSecondaryActionRow(
                icon: "square.and.arrow.down",
                tint: .indigo,
                iconBoxSize: clampedIconSize,
                title: NSLocalizedString("导入配置包或角色卡", value: "Import Config or Character Card", comment: "起步卡导入配置标题"),
                subtitle: NSLocalizedString("恢复已有备份，或导入酒馆角色卡与世界书", value: "Restore backups, character cards, or worldbooks", comment: "起步卡导入配置副标题")
            ) {
                GuideNavigationCoordinator.shared.request(.dataImport)
            }

            Divider()
                .padding(.leading, dividerLeading)

            OnboardingSecondaryActionRow(
                icon: "compass.drawing",
                tint: .teal,
                iconBoxSize: clampedIconSize,
                title: NSLocalizedString("先逛逛软件有哪些功能", value: "Explore App Features First", comment: "起步卡功能导览标题"),
                subtitle: NSLocalizedString("了解角色扮演、记忆系统、工具调用与语音能力", value: "Learn about roleplay, memory, tools, and voice", comment: "起步卡功能导览副标题")
            ) {
                openGuide?(.tour)
            }
        }
        .clipShape(secondaryGroupShape)
        .background {
            if reduceTransparency {
                secondaryGroupShape.fill(Color(uiColor: .tertiarySystemGroupedBackground))
            } else {
                // 外层已是玻璃材质，内嵌分组仅用低透明度纯色阶差区分层级，避免双重模糊导致文字发糊。
                secondaryGroupShape.fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.035))
            }
        }
        .overlay {
            secondaryGroupShape.strokeBorder(
                Color.primary.opacity(reduceTransparency ? 0.16 : (colorScheme == .dark ? 0.10 : 0.06)),
                lineWidth: 0.5
            )
        }
    }

    private var cardBackground: some View {
        Group {
            if reduceTransparency {
                cardShape.fill(Color(uiColor: .secondarySystemBackground))
            } else if #available(iOS 26.0, *), isLiquidGlassEnabled {
                cardShape
                    .fill(colorScheme == .dark ? Color.black.opacity(0.20) : Color.white.opacity(0.24))
                    .glassEffect(.regular, in: cardShape)
            } else {
                cardShape.fill(.regularMaterial)
            }
        }
        .overlay {
            cardShape.strokeBorder(cardBorderGradient, lineWidth: 0.5)
        }
    }

    /// 模拟顶缘受光切边，并在浅色壁纸下提供微妙底缘界限以防糊边。
    private var cardBorderGradient: LinearGradient {
        if reduceTransparency {
            return LinearGradient(
                colors: [Color.primary.opacity(0.18), Color.primary.opacity(0.14)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        if colorScheme == .dark {
            return LinearGradient(
                colors: [Color.white.opacity(0.32), Color.white.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [Color.white.opacity(0.78), Color.black.opacity(0.09)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct OnboardingSecondaryActionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let icon: String
    let tint: Color
    let iconBoxSize: CGFloat
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                if !dynamicTypeSize.isAccessibilitySize {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tint.opacity(0.14))
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    .frame(width: iconBoxSize, height: iconBoxSize)
                    .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(OnboardingGroupedRowButtonStyle())
    }
}

/// 在按下瞬间给出背景与微缩放响应，松手沿临界阻尼恢复。
private struct OnboardingGroupedRowButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.065)
                    : Color.clear
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.99 : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 1.0),
                value: configuration.isPressed
            )
    }
}
