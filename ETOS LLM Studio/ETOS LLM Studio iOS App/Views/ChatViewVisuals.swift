// ============================================================================
// ChatViewVisuals.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 的背景、提示条、滚动按钮和顶部模糊视觉层。
// ============================================================================

import SwiftUI
import UIKit
import AVFoundation

extension ChatView {
    func memoryRetryStoppedNoticeBanner(text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .etFont(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            Text(text)
                .etFont(.footnote)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.memoryRetryStoppedNoticeMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .etFont(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("关闭提示", comment: ""))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 3)
    }

    /// Telegram 风格的背景层
    var telegramBackgroundLayer: some View {
        GeometryReader { geometry in
            Group {
                if viewModel.enableBackground,
                   viewModel.currentBackgroundIsVideo,
                   let videoURL = viewModel.currentBackgroundMediaURL {
                    ZStack {
                        if viewModel.backgroundContentMode == "fit" {
                            colorScheme == .dark ? Color.black : Color(uiColor: .systemBackground)
                        }

                        LoopingBackgroundVideoView(
                            url: videoURL,
                            contentMode: viewModel.backgroundContentMode
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        .clipped()
                        .blur(radius: viewModel.backgroundBlur)
                        .opacity(viewModel.backgroundOpacity)
                    }
                } else if viewModel.enableBackground,
                          let image = viewModel.currentBackgroundImageBlurredUIImage {
                    ZStack {
                        if viewModel.backgroundContentMode == "fit" {
                            colorScheme == .dark ? Color.black : Color(uiColor: .systemBackground)
                        }

                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(
                                contentMode: viewModel.backgroundContentMode == "fill" ? .fill : .fit
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            .clipped()
                            .opacity(viewModel.backgroundOpacity)
                    }
                } else {
                    TelegramDefaultBackground()
                }
            }
        }
    }

    var navBarFadeBlurOverlay: some View {
        GeometryReader { proxy in
            let adaptiveHeight = min(
                navBarBlurFadeMaxHeight,
                max(navBarBlurFadeMinHeight, proxy.size.height * navBarBlurFadeHeightRatio)
            )
            BlurView(style: .regular)
                .mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.black, location: 0),
                            .init(color: Color.black.opacity(0.88), location: 0.28),
                            .init(color: Color.black.opacity(0.22), location: 0.72),
                            .init(color: Color.black.opacity(0), location: 1)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(maxWidth: .infinity)
                .frame(height: navBarHeight + adaptiveHeight)
                .ignoresSafeArea(.container, edges: [.top, .horizontal])
                .allowsHitTesting(false)
        }
    }

    /// Telegram 风格滚动到底部按钮
    @ViewBuilder
    func telegramScrollToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    scrollToBottomButtonIcon
                        .background(
                            Circle()
                                .fill(scrollToBottomButtonMaterialOverlayColor)
                        )
                        .glassEffect(.clear.interactive(), in: Circle())
                        .overlay(
                            Circle()
                                .stroke(scrollToBottomButtonMaterialStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: scrollToBottomButtonMaterialShadowColor, radius: 6, x: 0, y: 2)
                } else {
                    scrollToBottomButtonIcon
                        .background(scrollToBottomButtonBackground)
                }
            } else {
                scrollToBottomButtonIcon
                    .background(scrollToBottomButtonBackground)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("滚动到底部", comment: ""))
    }

    var scrollToBottomButtonIcon: some View {
        Image(systemName: "chevron.down")
            .etFont(.system(size: 16, weight: .semibold))
            .foregroundColor(scrollToBottomButtonIconColor)
            .frame(width: scrollToBottomButtonSize, height: scrollToBottomButtonSize)
            .contentShape(Circle())
    }

    var scrollToBottomButtonBackground: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(
                Circle()
                    .fill(scrollToBottomButtonMaterialOverlayColor)
            )
            .overlay(
                Circle()
                    .stroke(scrollToBottomButtonMaterialStrokeColor, lineWidth: 0.5)
            )
            .shadow(color: scrollToBottomButtonMaterialShadowColor, radius: 6, x: 0, y: 2)
    }

    /// Telegram 风格历史加载提示
    @ViewBuilder
    var historyBanner: some View {
        let remainingCount = viewModel.remainingHistoryCount
        if viewModel.usesManualHistoryLoading && remainingCount > 0 && !viewModel.isHistoryFullyLoaded {
            let chunk = viewModel.historyLoadChunkCount
            Button {
                suppressAutoScrollOnce = true
                withAnimation {
                    viewModel.loadMoreHistoryChunk()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle")
                        .etFont(.system(size: 14))
                    Text(String(format: NSLocalizedString("加载更早的 %d 条消息", comment: ""), chunk))
                        .etFont(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .foregroundColor(TelegramColors.attachButtonColor)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background {
                    historyBannerBackground
                }
                .overlay(
                    Capsule()
                        .stroke(historyBannerStrokeColor, lineWidth: 0.8)
                )
                .shadow(color: scrollToBottomButtonShadowColor, radius: 6, x: 0, y: 2)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    var historyBannerBackground: some View {
        let shape = Capsule()
        if isLiquidGlassEnabled {
            if #available(iOS 26.0, *) {
                shape
                    .fill(Color(uiColor: .systemBackground).opacity(0.62))
                    .glassEffect(.regular.tint(scrollToBottomButtonGlassTintColor).interactive(), in: shape)
                    .clipShape(shape)
            } else {
                shape.fill(Color(uiColor: .systemBackground).opacity(0.9))
            }
        } else {
            shape.fill(Color(uiColor: .systemBackground).opacity(0.9))
        }
    }

    var historyBannerStrokeColor: Color {
        isLiquidGlassEnabled ? scrollToBottomButtonGlassStrokeColor : scrollToBottomButtonBorderColor
    }
}

private struct LoopingBackgroundVideoView: UIViewRepresentable {
    let url: URL
    let contentMode: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        context.coordinator.configure(view: view, url: url, contentMode: contentMode)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        context.coordinator.configure(view: uiView, url: url, contentMode: contentMode)
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.stop()
        uiView.playerLayer.player = nil
    }

    final class Coordinator {
        private var currentURL: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?

        func configure(view: PlayerContainerView, url: URL, contentMode: String) {
            view.playerLayer.videoGravity = contentMode == "fit" ? .resizeAspect : .resizeAspectFill
            if currentURL == url, view.playerLayer.player === player {
                player?.play()
                return
            }

            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = true
            player.actionAtItemEnd = .none
            looper = AVPlayerLooper(player: player, templateItem: item)
            view.playerLayer.player = player
            self.player = player
            currentURL = url
            player.play()
        }

        func stop() {
            player?.pause()
            player = nil
            looper = nil
            currentURL = nil
        }
    }

    final class PlayerContainerView: UIView {
        override static var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }
    }
}
