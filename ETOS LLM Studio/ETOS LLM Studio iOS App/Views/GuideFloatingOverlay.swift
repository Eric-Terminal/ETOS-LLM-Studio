// ============================================================================
// GuideFloatingOverlay.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 设置层中的 44pt 可拖动入口；展开后只有标题栏承接拖动，避免与聊天滚动冲突。
// ============================================================================

import SwiftUI
import ETOSCore

struct GuideFloatingOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject var controller: GuideConversationController
    @ObservedObject private var coordinator = GuideContextCoordinator.shared

    @State private var isPanelPresented = false
    @State private var isFullConversationPresented = false
    @State private var offset = CGSize.zero
    @State private var dragStartOffset: CGSize?
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let panelSize = resolvedPanelSize(in: geometry.size)
            let displayedSize = isPanelPresented ? panelSize : CGSize(width: 44, height: 44)
            let center = defaultCenter(for: displayedSize, in: geometry.size)
            let resolvedOffset = isDragging
                ? offset
                : clamped(offset, size: displayedSize, container: geometry.size)

            Group {
                if isPanelPresented {
                    panel(size: panelSize, container: geometry.size)
                } else {
                    floatingButton(container: geometry.size)
                }
            }
            .frame(width: displayedSize.width, height: displayedSize.height)
            .position(x: center.x + resolvedOffset.width, y: center.y + resolvedOffset.height)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: isPanelPresented)
        }
        .sheet(isPresented: $isFullConversationPresented) {
            NavigationStack {
                GuideFullConversationView(controller: controller)
            }
            .environmentObject(viewModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestGuideModelManagement)) { _ in
            isFullConversationPresented = false
            isPanelPresented = false
        }
    }

    private func floatingButton(container: CGSize) -> some View {
        Button {
            if dynamicTypeSize.isAccessibilitySize {
                isFullConversationPresented = true
            } else {
                isPanelPresented = true
            }
        } label: {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(floatingBackground(Circle()))
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .simultaneousGesture(dragGesture(
            size: CGSize(width: 44, height: 44),
            container: container,
            snapsToHorizontalEdge: true
        ))
        .accessibilityLabel(NSLocalizedString("打开页面向导", comment: "向导浮球辅助标签"))
        .accessibilityHint(currentPageAccessibilityHint)
    }

    private func panel(size: CGSize, container: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(NSLocalizedString("页面向导", comment: "向导面板标题"))
                        .font(.headline)
                    Text(coordinator.activePage?.title ?? NSLocalizedString("当前页面", comment: "向导未知页面标题"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    isFullConversationPresented = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel(NSLocalizedString("展开向导", comment: "展开向导按钮"))
                Button {
                    controller.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(controller.messages.isEmpty && controller.pendingProposal == nil)
                .accessibilityLabel(NSLocalizedString("清空向导上下文", comment: "清空向导按钮"))
                Button {
                    isPanelPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(NSLocalizedString("收起向导", comment: "收起向导按钮"))
            }
            .padding(.horizontal)
            .frame(height: 48)
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size, container: container))

            Divider()
            GuideConversationView(controller: controller, compact: true)
                .environmentObject(viewModel)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(floatingBackground(RoundedRectangle(cornerRadius: 22, style: .continuous)))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
    }

    private func floatingBackground<S: Shape>(_ shape: S) -> some View {
        Group {
            if reduceTransparency {
                shape.fill(Color(uiColor: .secondarySystemBackground))
            } else if #available(iOS 26.0, *) {
                shape
                    .fill(Color.clear)
                    .glassEffect(.clear, in: shape)
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .overlay(shape.stroke(Color.white.opacity(0.24), lineWidth: 0.5))
    }

    private func resolvedPanelSize(in container: CGSize) -> CGSize {
        CGSize(
            width: min(380, max(280, container.width - 24)),
            height: min(520, max(320, container.height * 0.52))
        )
    }

    private func defaultCenter(for size: CGSize, in container: CGSize) -> CGPoint {
        CGPoint(
            x: max(size.width / 2 + 12, container.width - size.width / 2 - 12),
            y: max(size.height / 2 + 12, container.height - size.height / 2 - 80)
        )
    }

    private func dragGesture(
        size: CGSize,
        container: CGSize,
        snapsToHorizontalEdge: Bool = false
    ) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if dragStartOffset == nil { dragStartOffset = offset }
                isDragging = true
                let start = dragStartOffset ?? offset
                let candidate = CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                )
                offset = rubberBanded(candidate, size: size, container: container)
            }
            .onEnded { value in
                let start = dragStartOffset ?? offset
                let candidate = CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                )
                let bounded = clamped(candidate, size: size, container: container)
                offset = snapsToHorizontalEdge
                    ? snappedToHorizontalEdge(bounded, size: size, container: container)
                    : bounded
                dragStartOffset = nil
                isDragging = false
            }
    }

    private func snappedToHorizontalEdge(
        _ candidate: CGSize,
        size: CGSize,
        container: CGSize
    ) -> CGSize {
        let center = defaultCenter(for: size, in: container)
        let currentX = center.x + candidate.width
        let leftX = size.width / 2 + 8
        let rightX = max(leftX, container.width - size.width / 2 - 8)
        let targetX = currentX < container.width / 2 ? leftX : rightX
        return CGSize(width: targetX - center.x, height: candidate.height)
    }

    private func clamped(_ candidate: CGSize, size: CGSize, container: CGSize) -> CGSize {
        let center = defaultCenter(for: size, in: container)
        let minX = size.width / 2 + 8
        let maxX = max(minX, container.width - size.width / 2 - 8)
        let minY = size.height / 2 + 8
        let maxY = max(minY, container.height - size.height / 2 - 8)
        let x = min(max(center.x + candidate.width, minX), maxX)
        let y = min(max(center.y + candidate.height, minY), maxY)
        return CGSize(width: x - center.x, height: y - center.y)
    }

    private func rubberBanded(_ candidate: CGSize, size: CGSize, container: CGSize) -> CGSize {
        let center = defaultCenter(for: size, in: container)
        let minX = size.width / 2 + 8
        let maxX = max(minX, container.width - size.width / 2 - 8)
        let minY = size.height / 2 + 8
        let maxY = max(minY, container.height - size.height / 2 - 8)
        let x = rubberBand(center.x + candidate.width, minimum: minX, maximum: maxX)
        let y = rubberBand(center.y + candidate.height, minimum: minY, maximum: maxY)
        return CGSize(width: x - center.x, height: y - center.y)
    }

    private func rubberBand(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        if value < minimum {
            return minimum - (minimum - value) * 0.2
        }
        if value > maximum {
            return maximum + (value - maximum) * 0.2
        }
        return value
    }

    private var currentPageAccessibilityHint: String {
        guard let title = coordinator.activePage?.title else { return "" }
        return String(
            format: NSLocalizedString("询问“%@”页面的配置方法", comment: "向导浮球当前页面辅助说明"),
            title
        )
    }
}
