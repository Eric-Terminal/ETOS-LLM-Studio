// ============================================================================
// ChatViewCardMessageComposer.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 iOS 卡片输入栏的自然增高编辑区与底部工具栏。
// ============================================================================

import SwiftUI
import ETOSCore

extension TelegramMessageComposer {
    var usesCardComposer: Bool {
        ChatComposerStyle.normalized(appConfig.chatComposerStyle) == .card
    }

    var cardComposerLayout: some View {
        cardComposerContent
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .bottom)
            .animation(adaptiveComposerAnimation, value: adaptivePresentation)
    }

    private var cardComposerContent: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        return VStack(spacing: 0) {
            if adaptivePresentation == .requestControls {
                adaptiveRequestControlsPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                Divider()
                    .padding(.horizontal)
                    .transition(.opacity)
            }

            if adaptivePresentation == .speech {
                adaptiveSpeechContent
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                cardTextEditor
                    .transition(.opacity)
            }

            cardToolbar
        }
        .frame(maxWidth: .infinity)
        .background(glassRoundedBackground(cornerRadius: 22))
        .clipShape(shape)
        .contentShape(shape)
    }

    private var cardTextEditor: some View {
        TextField(
            NSLocalizedString("Message", comment: "聊天输入框占位文本"),
            text: $text,
            axis: .vertical
        )
        .etFont(.system(size: 16))
        .focused(focus)
        .textFieldStyle(.plain)
        // 交给系统文本控件逐行扩展；达到六行后内部滚动，避免在输入链路中重复测量全文。
        .lineLimit(1...6)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: InputBarRectKey.self,
                    value: proxy.frame(in: .named(ChatView.flightCoordinateSpace))
                )
            }
        )
    }

    private var cardToolbar: some View {
        HStack(spacing: 6) {
            if adaptivePresentation != .speech {
                attachmentMenuButton(
                    size: 40,
                    embeddedInCard: true
                )

                if adaptiveShowsRequestControlsButton {
                    cardRequestControlsButton
                        .transition(.scale(scale: 0.82).combined(with: .opacity))
                }
            }

            Spacer(minLength: 0)

            if adaptivePresentation != .speech, viewModel.enableSpeechInput {
                cardSpeechButton
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
            }

            adaptiveActionButton(
                size: 40,
                participatesInGlassContainer: false,
                embeddedInCard: true
            )
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(minHeight: 48)
        .animation(adaptiveComposerAnimation, value: adaptiveShowsRequestControlsButton)
        .animation(adaptiveComposerAnimation, value: viewModel.enableSpeechInput)
    }

    private var cardRequestControlsButton: some View {
        Button(action: adaptiveToggleRequestControls) {
            Image(systemName: "slider.horizontal.3")
                .etFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    adaptivePresentation == .requestControls
                        ? Color.accentColor
                        : TelegramColors.attachButtonColor
                )
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(ComposerPressButtonStyle())
        .accessibilityLabel(NSLocalizedString("请求控制", comment: ""))
    }

    private var cardSpeechButton: some View {
        Button(action: adaptiveStartSpeechInput) {
            Image(systemName: "mic.fill")
                .etFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(TelegramColors.attachButtonColor)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(ComposerPressButtonStyle())
        .accessibilityLabel(NSLocalizedString("开始语音输入", comment: ""))
    }
}
