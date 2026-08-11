// ============================================================================
// ChatLocalLinuxTerminalPreview.swift
// ============================================================================
// ETOS LLM Studio
//
// 聊天页只缩略显示已经存在的独立用户终端；预览不会启动 Linux 或创建新 PTY。
// ============================================================================

import ETOSCore
import SwiftUI

struct LocalLinuxTerminalFloatingPreview: View {
    @Environment(\.colorScheme) private var colorScheme

    let isEnabled: Bool
    let containerSize: CGSize
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    @Binding var offset: CGSize
    let isLiquidGlassEnabled: Bool
    let onOpen: (UUID) -> Void

    @State private var activeTerminalID: UUID?
    @State private var activeTerminalCount = 0
    @State private var presentation = LocalLinuxTerminalPresentation.empty
    @State private var dragStartOffset: CGSize?

    private let panelSize = CGSize(width: 168, height: 112)

    var body: some View {
        Group {
            if let activeTerminalID {
                Button {
                    onOpen(activeTerminalID)
                } label: {
                    panelContent(jobID: activeTerminalID)
                }
                .buttonStyle(.plain)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .simultaneousGesture(dragGesture)
                .position(
                    x: defaultCenter.x + clampedOffset.width,
                    y: defaultCenter.y + clampedOffset.height
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .accessibilityLabel(NSLocalizedString("打开用户终端", comment: "Open user Linux terminal"))
            }
        }
        .task(id: isEnabled) {
            await observeTerminalActivity()
        }
        .task(id: terminalOutputObservationID) {
            await observeTerminalOutput()
        }
    }

    private func panelContent(jobID: UUID) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .etFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TelegramColors.attachButtonColor)

                Text(NSLocalizedString("用户终端", comment: "User terminal preview title"))
                    .etFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if activeTerminalCount > 1 {
                    Label("\(activeTerminalCount)", systemImage: "rectangle.stack")
                        .labelStyle(.titleAndIcon)
                        .etFont(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(jobID.uuidString.prefix(4)))
                        .etFont(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .etFont(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)

            Group {
                if presentation.plainText.isEmpty {
                    Text(NSLocalizedString("终端正在启动…", comment: "Linux terminal starting placeholder"))
                        .foregroundStyle(.secondary)
                } else {
                    Text(presentation.attributedText)
                }
            }
            .font(.system(size: 6, design: .monospaced))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(6)
            .background(terminalCanvasColor)
            .clipped()
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func observeTerminalActivity() async {
        guard isEnabled else {
            activeTerminalID = nil
            activeTerminalCount = 0
            presentation = .empty
            return
        }

        let updates = await LocalLinuxRuntimeController.shared.updates()
        for await snapshot in updates {
            guard !Task.isCancelled else { return }
            if snapshot.activeTerminalCount == 0 {
                activeTerminalID = nil
                activeTerminalCount = 0
                presentation = .empty
                continue
            }
            let terminals = await LocalLinuxJobScheduler.shared.activeStandaloneUserTerminals()
            let terminalIDs = terminals.map(\.id)
            activeTerminalCount = terminalIDs.count
            let nextID = activeTerminalID.flatMap { terminalIDs.contains($0) ? $0 : nil }
                ?? terminalIDs.first
            if activeTerminalID != nextID {
                activeTerminalID = nextID
                presentation = .empty
            }
        }
    }

    private func observeTerminalOutput() async {
        guard let terminalID = activeTerminalID else { return }
        let appearance = terminalAppearance
        while !Task.isCancelled, activeTerminalID == terminalID {
            do {
                presentation = try await LocalLinuxJobScheduler.shared
                    .userVisibleTerminalPreviewPresentation(
                        jobID: terminalID,
                        maximumLines: 10,
                        appearance: appearance
                    )
            } catch {
                activeTerminalID = nil
                presentation = .empty
                return
            }
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if dragStartOffset == nil {
                    dragStartOffset = offset
                }
                let startOffset = dragStartOffset ?? offset
                offset = clamp(
                    CGSize(
                        width: startOffset.width + value.translation.width,
                        height: startOffset.height + value.translation.height
                    )
                )
            }
            .onEnded { value in
                let startOffset = dragStartOffset ?? offset
                offset = clamp(
                    CGSize(
                        width: startOffset.width + value.translation.width,
                        height: startOffset.height + value.translation.height
                    )
                )
                dragStartOffset = nil
            }
    }

    private var clampedOffset: CGSize {
        clamp(offset)
    }

    private var terminalAppearance: LocalLinuxTerminalAppearance {
        colorScheme == .dark ? .dark : .light
    }

    private var terminalCanvasColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var terminalOutputObservationID: String {
        "\(activeTerminalID?.uuidString ?? "none")|\(terminalAppearance)"
    }

    private func clamp(_ candidate: CGSize) -> CGSize {
        let minX = panelSize.width / 2 + 12
        let maxX = max(minX, containerSize.width - panelSize.width / 2 - 12)
        let minY = topPadding + panelSize.height / 2
        let maxY = max(minY, containerSize.height - bottomPadding - panelSize.height / 2)
        let x = min(max(defaultCenter.x + candidate.width, minX), maxX)
        let y = min(max(defaultCenter.y + candidate.height, minY), maxY)
        return CGSize(width: x - defaultCenter.x, height: y - defaultCenter.y)
    }

    private var defaultCenter: CGPoint {
        CGPoint(
            x: panelSize.width / 2 + 16,
            y: max(
                topPadding + panelSize.height / 2,
                containerSize.height - bottomPadding - panelSize.height / 2
            )
        )
    }

    private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    shape
                        .fill(Color.clear)
                        .glassEffect(.clear, in: shape)
                        .overlay(shape.fill(glassOverlayColor))
                        .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
                        .shadow(color: glassShadowColor, radius: 8, x: 0, y: 3)
                } else {
                    materialBackground(shape: shape)
                }
            } else {
                materialBackground(shape: shape)
            }
        }
    }

    private func materialBackground(shape: RoundedRectangle) -> some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(glassOverlayColor))
            .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
            .shadow(color: glassShadowColor, radius: 8, x: 0, y: 3)
    }

    private var glassOverlayColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.2)
    }

    private var glassStrokeColor: Color {
        Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28)
    }

    private var glassShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1)
    }
}
