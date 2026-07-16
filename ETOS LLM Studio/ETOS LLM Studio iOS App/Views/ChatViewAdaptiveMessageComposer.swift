// ============================================================================
// ChatViewAdaptiveMessageComposer.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 iOS 自适应输入栏的状态映射、连续形变和请求控制面板。
// ============================================================================

import Foundation
import SwiftUI
import UIKit
import ETOSCore

enum AdaptiveComposerPresentation: Equatable {
    case idle
    case editing
    case expandedText
    case requestControls
    case speech
}

struct ComposerPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension TelegramMessageComposer {
    var usesAdaptiveComposer: Bool {
        ChatComposerStyle.normalized(appConfig.chatComposerStyle) == .adaptive
    }

    var adaptiveControlSize: CGFloat { 44 }

    var adaptiveComposerAnimation: Animation? {
        accessibilityReduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.34, dampingFraction: 0.94)
    }

    var adaptivePresentation: AdaptiveComposerPresentation {
        if inlineSpeechRecorder.phase.isActive {
            return .speech
        }
        if isRequestControlsExpanded {
            return .requestControls
        }
        if isExpandedComposer {
            return .expandedText
        }
        if focus.wrappedValue {
            return .editing
        }
        return .idle
    }

    @ViewBuilder
    var adaptiveComposerContent: some View {
        Group {
            if #available(iOS 26.0, *), viewModel.enableLiquidGlass {
                GlassEffectContainer(spacing: 8) {
                    adaptiveGlassComposerRow
                }
            } else {
                adaptiveComposerRow
            }
        }
        .onAppear(perform: adaptiveRefreshRequestControls)
        .onChange(of: viewModel.selectedModel?.id) { _, _ in
            adaptiveRefreshRequestControls()
        }
    }

    private var adaptiveComposerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if adaptiveShowsAttachmentButton {
                attachmentMenuButton(size: adaptiveControlSize)
                    .transition(
                        .scale(scale: 0.82, anchor: .trailing)
                            .combined(with: .opacity)
                    )
            }

            adaptiveCenterContainer(participatesInGlassContainer: false)

            if adaptiveShowsActionButton {
                adaptiveActionButton(participatesInGlassContainer: false)
                    .transition(
                        .scale(scale: 0.82, anchor: .leading)
                            .combined(with: .opacity)
                    )
            }
        }
    }

    @available(iOS 26.0, *)
    private var adaptiveGlassComposerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if adaptiveShowsAttachmentButton {
                attachmentMenuButton(
                    size: adaptiveControlSize,
                    participatesInGlassContainer: true
                )
                    .glassEffectID("adaptive-attachment", in: adaptiveGlassNamespace)
                    .transition(
                        .scale(scale: 0.82, anchor: .trailing)
                            .combined(with: .opacity)
                    )
            }

            adaptiveCenterContainer(participatesInGlassContainer: true)
                .glassEffectID("adaptive-center", in: adaptiveGlassNamespace)

            if adaptiveShowsActionButton {
                adaptiveActionButton(participatesInGlassContainer: true)
                    .glassEffectID("adaptive-action", in: adaptiveGlassNamespace)
                    .transition(
                        .scale(scale: 0.82, anchor: .leading)
                            .combined(with: .opacity)
                    )
            }
        }
    }

    private var adaptiveShowsAttachmentButton: Bool {
        adaptivePresentation != .expandedText
            && adaptivePresentation != .requestControls
            && adaptivePresentation != .speech
    }

    private var adaptiveShowsActionButton: Bool {
        adaptivePresentation != .requestControls
    }

    @ViewBuilder
    private func adaptiveCenterContainer(
        participatesInGlassContainer: Bool
    ) -> some View {
        let cornerRadius = adaptivePresentation == .requestControls
            ? CGFloat(24)
            : adaptiveControlSize / 2
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(iOS 26.0, *),
           viewModel.enableLiquidGlass,
           participatesInGlassContainer {
            adaptiveCenterForeground(shape: shape)
                .background(shape.fill(glassOverlayColor))
                .glassEffect(.clear, in: shape)
                .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
                .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                .animation(adaptiveComposerAnimation, value: adaptivePresentation)
        } else {
            adaptiveCenterForeground(shape: shape)
                .background(glassRoundedBackground(cornerRadius: cornerRadius))
                .animation(adaptiveComposerAnimation, value: adaptivePresentation)
        }
    }

    private func adaptiveCenterForeground(
        shape: RoundedRectangle
    ) -> some View {
        VStack(spacing: 0) {
            if adaptivePresentation == .requestControls {
                adaptiveRequestControlsPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                Divider()
                    .padding(.horizontal)
                    .transition(.opacity)
            }

            if adaptivePresentation == .speech {
                adaptiveSpeechContent
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                adaptiveInputStrip
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .clipShape(shape)
        .contentShape(shape)
    }

    private var adaptiveRequestControlsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.tint)

                    Text(NSLocalizedString("请求控制", comment: ""))
                        .etFont(.headline)

                    Spacer()

                    Text(adaptiveModelName)
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let selectedModel = viewModel.selectedModel {
                    if adaptiveRequestControls.isEmpty {
                        Text(NSLocalizedString("当前模型没有可用的请求控制。", comment: ""))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 14) {
                            ChatRequestBodyControlRows(
                                runnableModel: selectedModel,
                                controls: adaptiveRequestControls,
                                onDone: adaptiveCloseRequestControls,
                                optionPresentation: .menu
                            )
                        }
                    }
                } else {
                    Text(NSLocalizedString("请先激活一个聊天模型。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .frame(height: adaptiveRequestControlsPanelHeight)
    }

    private var adaptiveRequestControlsPanelHeight: CGFloat {
        let maximumHeight = min(UIScreen.main.bounds.height * 0.38, 340)
        let estimatedContentHeight = 82 + CGFloat(adaptiveRequestControls.count) * 68
        return min(maximumHeight, max(124, estimatedContentHeight))
    }

    private var adaptiveInputStrip: some View {
        let targetHeight = adaptivePresentation == .expandedText
            ? adaptiveExpandedInputHeight
            : adaptiveControlSize

        return ZStack(alignment: .topLeading) {
            adaptiveTextEditor

            HStack(spacing: 0) {
                if adaptiveShowsRequestControlsButton {
                    adaptiveRequestControlsButton
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }

                Spacer(minLength: 0)

                if adaptiveShowsSpeechButton {
                    adaptiveSpeechButton
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .frame(height: adaptiveControlSize, alignment: .top)
        }
        .frame(minHeight: targetHeight, maxHeight: targetHeight)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: InputBarRectKey.self,
                    value: proxy.frame(in: .named(ChatView.flightCoordinateSpace))
                )
            }
        )
        .animation(adaptiveComposerAnimation, value: adaptiveShowsRequestControlsButton)
        .animation(adaptiveComposerAnimation, value: viewModel.enableSpeechInput)
    }

    private var adaptiveTextEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .etFont(.system(size: 16))
                .focused(focus)
                .scrollContentBackground(.hidden)
                .scrollDisabled(adaptivePresentation != .expandedText)
                .padding(.vertical, adaptivePresentation == .expandedText ? 8 : 2)
                .padding(.leading, adaptiveTextLeadingInset)
                .padding(.trailing, adaptiveTextTrailingInset)

            if text.isEmpty {
                Text(NSLocalizedString("Message", comment: "聊天输入框占位文本"))
                    .etFont(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, adaptivePresentation == .expandedText ? 16 : 10)
                    .padding(.leading, adaptiveTextLeadingInset + 5)
                    .allowsHitTesting(false)
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                if isRequestControlsExpanded {
                    adaptiveBeginEditing()
                }
            }
        )
    }

    private var adaptiveShowsRequestControlsButton: Bool {
        !adaptiveRequestControls.isEmpty && adaptivePresentation != .expandedText
    }

    private var adaptiveShowsSpeechButton: Bool {
        viewModel.enableSpeechInput
    }

    // 只为实际显示的内置按钮预留边距，多行态把横向空间完整还给正文。
    private var adaptiveTextLeadingInset: CGFloat {
        adaptiveShowsRequestControlsButton ? adaptiveControlSize : 6
    }

    private var adaptiveTextTrailingInset: CGFloat {
        adaptiveShowsSpeechButton ? adaptiveControlSize : 6
    }

    private var adaptiveExpandedInputHeight: CGFloat {
        let fontScale = CGFloat(
            FontLibrary.effectiveFontScale(
                appConfig.fontCustomScale,
                isCustomFontEnabled: appConfig.fontUseCustomFonts
            )
        )
        let rawHeight = UIScreen.main.bounds.height * 0.3
        return max(160 * fontScale, min(rawHeight, 360 * fontScale))
    }

    private var adaptiveRequestControlsButton: some View {
        Button(action: adaptiveToggleRequestControls) {
            Image(systemName: "slider.horizontal.3")
                .etFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    adaptivePresentation == .requestControls
                        ? Color.accentColor
                        : TelegramColors.attachButtonColor
                )
                .frame(width: adaptiveControlSize, height: adaptiveControlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(ComposerPressButtonStyle())
        .accessibilityLabel(NSLocalizedString("请求控制", comment: ""))
    }

    private var adaptiveSpeechButton: some View {
        Button(action: adaptiveStartSpeechInput) {
            Image(systemName: "mic.fill")
                .etFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(TelegramColors.attachButtonColor)
                .frame(width: adaptiveControlSize, height: adaptiveControlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(ComposerPressButtonStyle())
        .accessibilityLabel(NSLocalizedString("开始语音输入", comment: ""))
    }

    @ViewBuilder
    private var adaptiveSpeechContent: some View {
        switch inlineSpeechRecorder.phase {
        case .idle:
            EmptyView()
        case .preparing, .recording:
            HStack(spacing: 10) {
                InlineVoiceWaveformView(
                    samples: inlineSpeechRecorder.waveformSamples,
                    tint: .red,
                    minimumBarOpacity: 0.82,
                    isProcessing: false
                )
                .frame(height: 28)

                Text(adaptiveSpeechDuration)
                    .etFont(.system(size: 13, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.red)

                Button(action: stopInlineSpeechRecording) {
                    Image(systemName: "stop.fill")
                        .etFont(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.red.opacity(0.8)))
                        .frame(width: adaptiveControlSize, height: adaptiveControlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ComposerPressButtonStyle())
                .accessibilityLabel(NSLocalizedString("停止录音", comment: ""))
                .disabled(inlineSpeechRecorder.phase == .preparing)
                .opacity(inlineSpeechRecorder.phase == .preparing ? 0.58 : 1)
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .frame(height: adaptiveControlSize)
        case .preview, .transcribing:
            HStack(spacing: 6) {
                Button(action: cancelInlineSpeechRecording) {
                    Image(systemName: "xmark")
                        .etFont(.system(size: 14, weight: .semibold))
                        .frame(width: adaptiveControlSize, height: adaptiveControlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ComposerPressButtonStyle())
                .accessibilityLabel(NSLocalizedString("取消录音", comment: ""))
                .disabled(inlineSpeechRecorder.phase == .transcribing)

                if let transcript = inlineSpeechPreparedTranscript, !transcript.isEmpty {
                    Text(transcript)
                        .etFont(.footnote)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button {
                        inlineSpeechRecorder.togglePreviewPlayback()
                    } label: {
                        Image(systemName: inlineSpeechRecorder.isPlayingPreview ? "pause.fill" : "play.fill")
                            .etFont(.system(size: 12, weight: .bold))
                            .frame(width: adaptiveControlSize, height: adaptiveControlSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ComposerPressButtonStyle())
                    .accessibilityLabel(NSLocalizedString("播放录音", comment: ""))
                    .disabled(inlineSpeechRecorder.phase == .transcribing)

                    InlineVoiceWaveformView(
                        samples: inlineSpeechRecorder.waveformSamples,
                        tint: .secondary,
                        minimumBarOpacity: 0.52,
                        isProcessing: inlineSpeechRecorder.phase == .transcribing
                    )
                    .frame(height: 28)
                }

                if inlineSpeechRecorder.phase == .transcribing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 34, height: 34)
                        .accessibilityLabel(NSLocalizedString("语音转写中", comment: ""))
                } else {
                    Button(action: confirmInlineSpeechRecording) {
                        Image(systemName: "checkmark")
                            .etFont(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.accentColor))
                            .frame(width: adaptiveControlSize, height: adaptiveControlSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ComposerPressButtonStyle())
                    .accessibilityLabel(NSLocalizedString("完成", comment: ""))
                }
            }
            .padding(.horizontal, 5)
            .frame(height: adaptiveControlSize)
        }
    }

    private func adaptiveActionButton(
        participatesInGlassContainer: Bool
    ) -> some View {
        Button(action: adaptiveHandleAction) {
            adaptiveActionLabel(
                participatesInGlassContainer: participatesInGlassContainer
            )
        }
        .buttonStyle(ComposerPressButtonStyle())
        .disabled(adaptiveActionIsDisabled)
        .accessibilityLabel(adaptiveActionAccessibilityLabel)
    }

    @ViewBuilder
    private func adaptiveActionLabel(
        participatesInGlassContainer: Bool
    ) -> some View {
        let label = Image(systemName: adaptiveActionIconName)
            .etFont(.system(size: 17, weight: .semibold))
            .foregroundStyle(adaptiveActionForegroundColor)
            .frame(width: adaptiveControlSize, height: adaptiveControlSize)

        if #available(iOS 26.0, *),
           viewModel.enableLiquidGlass,
           participatesInGlassContainer {
            label
                .background(Circle().fill(adaptiveGlassActionFill))
                .glassEffect(.clear.interactive(), in: Circle())
                .overlay(Circle().stroke(glassStrokeColor, lineWidth: 0.5))
                .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
        } else {
            label
                .background(adaptiveActionBackground)
        }
    }

    private var adaptiveGlassActionFill: Color {
        if isSending {
            return Color.red.opacity(0.85 * 0.82)
        }
        if adaptiveHasContent {
            let fill = viewModel.canSendMessage
                ? TelegramColors.sendButtonColor
                : Color.primary.opacity(0.12)
            return fill.opacity(0.82)
        }
        if viewModel.canQuickRetryLatestMessage,
           !inlineSpeechRecorder.phase.isActive {
            return TelegramColors.sendButtonColor.opacity(0.82)
        }
        return glassOverlayColor
    }

    private var adaptiveHasContent: Bool {
        !text.isEmpty
            || viewModel.pendingAudioAttachment != nil
            || !viewModel.pendingImageAttachments.isEmpty
            || !viewModel.pendingFileAttachments.isEmpty
    }

    private var adaptiveActionIconName: String {
        if isSending {
            return "stop.fill"
        }
        if adaptiveHasContent {
            return "arrow.up"
        }
        if viewModel.canQuickRetryLatestMessage, !inlineSpeechRecorder.phase.isActive {
            return "arrow.clockwise"
        }
        return "arrow.up"
    }

    private var adaptiveActionForegroundColor: Color {
        if isSending
            || (viewModel.canQuickRetryLatestMessage
                && !adaptiveHasContent
                && !inlineSpeechRecorder.phase.isActive) {
            return .white
        }
        if adaptiveHasContent {
            return viewModel.canSendMessage ? .white : Color.primary.opacity(0.55)
        }
        return TelegramColors.attachButtonColor
    }

    @ViewBuilder
    private var adaptiveActionBackground: some View {
        if isSending {
            actionCircleBackground(fill: Color.red.opacity(0.85))
        } else if adaptiveHasContent {
            actionCircleBackground(
                fill: viewModel.canSendMessage
                    ? TelegramColors.sendButtonColor
                    : Color.primary.opacity(0.12)
            )
        } else if viewModel.canQuickRetryLatestMessage, !inlineSpeechRecorder.phase.isActive {
            actionCircleBackground(fill: TelegramColors.sendButtonColor)
        } else {
            glassCircleBackground
        }
    }

    private var adaptiveActionIsDisabled: Bool {
        if inlineSpeechRecorder.phase.isActive, !isSending {
            return true
        }
        return !isSending && adaptiveHasContent && !viewModel.canSendMessage
    }

    private var adaptiveActionAccessibilityLabel: String {
        if isSending {
            return NSLocalizedString("停止生成", comment: "")
        }
        if viewModel.canQuickRetryLatestMessage,
           !adaptiveHasContent,
           !inlineSpeechRecorder.phase.isActive {
            return NSLocalizedString("重试", comment: "")
        }
        return NSLocalizedString("发送", comment: "")
    }

    private var adaptiveModelName: String {
        viewModel.selectedModel?.model.displayName
            ?? NSLocalizedString("选择模型", comment: "")
    }

    private var adaptiveSpeechDuration: String {
        let totalSeconds = max(0, Int(inlineSpeechRecorder.recordingDuration.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func adaptiveToggleRequestControls() {
        let willExpand = !isRequestControlsExpanded
        if willExpand {
            adaptiveRefreshRequestControls()
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(adaptiveComposerAnimation) {
            focus.wrappedValue = false
            isExpandedComposer = false
            isRequestControlsExpanded = willExpand
        }
    }

    private func adaptiveCloseRequestControls() {
        withAnimation(adaptiveComposerAnimation) {
            isRequestControlsExpanded = false
        }
    }

    private func adaptiveBeginEditing() {
        withAnimation(adaptiveComposerAnimation) {
            isRequestControlsExpanded = false
            focus.wrappedValue = true
        }
    }

    private func adaptiveStartSpeechInput() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(adaptiveComposerAnimation) {
            isRequestControlsExpanded = false
            isExpandedComposer = false
            focus.wrappedValue = false
        }
        startInlineSpeechRecording()
    }

    private func adaptiveHandleAction() {
        if isSending {
            stopAction()
        } else if adaptiveHasContent {
            adaptiveCloseRequestControls()
            sendAction()
        } else if viewModel.canQuickRetryLatestMessage {
            adaptiveCloseRequestControls()
            viewModel.quickRetryLatestMessage()
        } else {
            adaptiveBeginEditing()
        }
    }

    private func adaptiveRefreshRequestControls() {
        let controls = viewModel.selectedModel?.model.requestBodyControls.filter(\.isEnabled) ?? []
        adaptiveRequestControls = controls
        if controls.isEmpty, isRequestControlsExpanded {
            withAnimation(adaptiveComposerAnimation) {
                isRequestControlsExpanded = false
            }
        }
    }
}
