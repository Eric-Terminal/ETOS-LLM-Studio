// ============================================================================
// ETAdvancedMarkdownRendererImageSupport.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 负责 watchOS Markdown 渲染器的图片预览、缩放和占位视图。
// ============================================================================

import Foundation
import SwiftUI
import MarkdownUI

struct ETWatchMarkdownImagePreviewItem: Identifiable {
    let url: URL

    var id: String {
        url.absoluteString
    }
}

struct ETWatchMarkdownImageProvider: ImageProvider {
    let onActivate: (ETWatchMarkdownImagePreviewItem) -> Void

    func makeImage(url: URL?) -> some View {
        ETWatchMarkdownImageThumbnail(
            url: url,
            onActivate: onActivate
        )
    }
}

private struct ETWatchMarkdownImageThumbnail: View {
    let url: URL?
    let onActivate: (ETWatchMarkdownImagePreviewItem) -> Void

    private let cornerRadius: CGFloat = 10

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
                    switch phase {
                    case .empty:
                        loadingPlaceholder
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    case .failure:
                        failurePlaceholder
                    @unknown default:
                        failurePlaceholder
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onTapGesture {
                    onActivate(.init(url: url))
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(NSLocalizedString("点按后可使用数码表冠缩放图片", comment: ""))
            } else {
                failurePlaceholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.14))
            .aspectRatio(4 / 3, contentMode: .fit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
            }
    }

    private var failurePlaceholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.14))
            .aspectRatio(4 / 3, contentMode: .fit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .etFont(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("图片载入失败", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
    }
}

struct ETWatchMarkdownImagePreviewSheet: View {
    let item: ETWatchMarkdownImagePreviewItem

    @State private var zoomScale = 1.0
    @State private var settledOffset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero

    private let maxZoomScale = 6.0
    private let contentInset: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                AsyncImage(url: item.url, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
                    switch phase {
                    case .empty:
                        loadingState
                    case .success(let image):
                        previewImage(
                            image,
                            containerSize: proxy.size
                        )
                    case .failure:
                        failureState
                    @unknown default:
                        failureState
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .focusable(true)
            .digitalCrownRotation(
                $zoomScale,
                from: 1.0,
                through: maxZoomScale,
                by: 0.05,
                sensitivity: .medium,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
            .onChange(of: zoomScale) { _, newValue in
                if newValue <= 1.01 {
                    settledOffset = .zero
                } else {
                    settledOffset = ETWatchMarkdownImageZoomMath.clampedOffset(
                        proposed: settledOffset,
                        containerSize: proxy.size,
                        contentSize: CGSize(
                            width: max(proxy.size.width - contentInset * 2, 1),
                            height: max(proxy.size.height - contentInset * 2, 1)
                        ),
                        scale: CGFloat(newValue)
                    )
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(NSLocalizedString("正在载入图片", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(Color.white.opacity(0.72))
        }
    }

    private var failureState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
                .etFont(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.78))
            Text(NSLocalizedString("图片载入失败", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .padding(12)
    }

    private func previewImage(_ image: Image, containerSize: CGSize) -> some View {
        let contentSize = CGSize(
            width: max(containerSize.width - contentInset * 2, 1),
            height: max(containerSize.height - contentInset * 2, 1)
        )
        let effectiveOffset = ETWatchMarkdownImageZoomMath.clampedOffset(
            proposed: CGSize(
                width: settledOffset.width + dragTranslation.width,
                height: settledOffset.height + dragTranslation.height
            ),
            containerSize: containerSize,
            contentSize: contentSize,
            scale: CGFloat(zoomScale)
        )

        return image
            .resizable()
            .scaledToFit()
            .frame(width: contentSize.width, height: contentSize.height)
            .scaleEffect(CGFloat(zoomScale))
            .offset(effectiveOffset)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragTranslation) { value, state, _ in
                        guard zoomScale > 1.01 else {
                            state = .zero
                            return
                        }
                        state = value.translation
                    }
                    .onEnded { value in
                        guard zoomScale > 1.01 else {
                            settledOffset = .zero
                            return
                        }
                        settledOffset = ETWatchMarkdownImageZoomMath.clampedOffset(
                            proposed: CGSize(
                                width: settledOffset.width + value.translation.width,
                                height: settledOffset.height + value.translation.height
                            ),
                            containerSize: containerSize,
                            contentSize: contentSize,
                            scale: CGFloat(zoomScale)
                        )
                    }
            )
    }
}

enum ETWatchMarkdownImageZoomMath {
    static func clampedOffset(
        proposed: CGSize,
        containerSize: CGSize,
        contentSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        guard scale > 1,
              containerSize.width > 0,
              containerSize.height > 0,
              contentSize.width > 0,
              contentSize.height > 0 else {
            return .zero
        }

        let maxX = max((contentSize.width * scale - containerSize.width) / 2, 0)
        let maxY = max((contentSize.height * scale - containerSize.height) / 2, 0)

        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}
