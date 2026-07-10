// ============================================================================
// WatchRequestBodySliderColorSettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 编辑单条结构化控制滑块的低值与高值端点颜色。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct WatchRequestBodySliderColorSettingsView: View {
    @Binding var control: ModelRequestBodyControl

    var body: some View {
        Form {
            Section {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                resolvedPalette.color(at: 0),
                                resolvedPalette.color(at: 0.34),
                                resolvedPalette.color(at: 0.68),
                                resolvedPalette.color(at: 1)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(height: 64)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                    }
                    .accessibilityHidden(true)
            } header: {
                Text(NSLocalizedString("预览", comment: ""))
            }

            Section {
                colorEditorLink(
                    titleKey: "低值颜色",
                    keyPath: \.sliderStartColorHex,
                    position: 0
                )
                colorEditorLink(
                    titleKey: "高值颜色",
                    keyPath: \.sliderEndColorHex,
                    position: 1
                )
            } footer: {
                Text(NSLocalizedString("分别设置低值与高值颜色，中间颜色会自动平滑过渡。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    control.sliderStartColorHex = nil
                    control.sliderEndColorHex = nil
                } label: {
                    Label(NSLocalizedString("恢复默认", comment: ""), systemImage: "arrow.counterclockwise")
                }
                .disabled(!hasCustomColors)
            }
        }
        .navigationTitle(NSLocalizedString("滑块颜色", comment: ""))
    }

    private var defaultPalette: WatchRequestBodySliderPalette {
        WatchRequestBodySliderPalette.defaultPalette(for: control)
    }

    private var resolvedPalette: WatchRequestBodySliderPalette {
        WatchRequestBodySliderPalette.resolved(for: control)
    }

    private var hasCustomColors: Bool {
        control.sliderStartColorHex != nil || control.sliderEndColorHex != nil
    }

    private func colorEditorLink(
        titleKey: String,
        keyPath: WritableKeyPath<ModelRequestBodyControl, String?>,
        position: Double
    ) -> some View {
        let title = NSLocalizedString(titleKey, comment: "Slider endpoint color")
        let fallback = defaultPalette.color(at: position)
        return NavigationLink {
            WatchColorEditorView(
                title: titleKey,
                hexValue: endpointHexBinding(keyPath, fallback: fallback),
                fallback: fallback,
                description: "分别设置低值与高值颜色，中间颜色会自动平滑过渡。",
                supportsOpacity: false
            )
        } label: {
            HStack {
                Text(title)
                Spacer()
                Circle()
                    .fill(endpointColor(keyPath, fallback: fallback))
                    .overlay {
                        Circle()
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    }
                    .frame(width: 14, height: 14)
            }
        }
    }

    private func endpointHexBinding(
        _ keyPath: WritableKeyPath<ModelRequestBodyControl, String?>,
        fallback: Color
    ) -> Binding<String> {
        let fallbackHex = ChatAppearanceColorCodec.hexRGBA(from: fallback) ?? "000000FF"
        return Binding(
            get: {
                control[keyPath: keyPath] ?? fallbackHex
            },
            set: { hex in
                if control[keyPath: keyPath] == nil,
                   hex.caseInsensitiveCompare(fallbackHex) == .orderedSame {
                    return
                }
                control[keyPath: keyPath] = hex
            }
        )
    }

    private func endpointColor(
        _ keyPath: WritableKeyPath<ModelRequestBodyControl, String?>,
        fallback: Color
    ) -> Color {
        guard let hex = control[keyPath: keyPath] else { return fallback }
        return ChatAppearanceColorCodec.color(from: hex, fallback: fallback)
    }
}
