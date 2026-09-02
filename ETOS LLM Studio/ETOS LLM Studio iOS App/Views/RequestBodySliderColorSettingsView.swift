// ============================================================================
// RequestBodySliderColorSettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// 编辑单条结构化控制滑块的低值与高值端点颜色。
// ============================================================================

import SwiftUI
import ETOSCore

struct RequestBodySliderColorSettingsView: View {
    @Binding var control: ModelRequestBodyControl

    var body: some View {
        Form {
            Section {
                Capsule()
                    .fill(resolvedPalette.gradient)
                    .frame(height: 28)
                    .overlay {
                        Capsule()
                            .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                    }
                    .accessibilityHidden(true)
            } header: {
                Text(NSLocalizedString("预览", comment: ""))
            }

            Section {
                ColorPicker(
                    NSLocalizedString("低值颜色", comment: "Slider low-value endpoint color"),
                    selection: endpointColorBinding(\.sliderStartColorHex, position: 0),
                    supportsOpacity: false
                )
                ColorPicker(
                    NSLocalizedString("高值颜色", comment: "Slider high-value endpoint color"),
                    selection: endpointColorBinding(\.sliderEndColorHex, position: 1),
                    supportsOpacity: false
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
        .navigationBarTitleDisplayMode(.inline)
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "settings-request-body-slider-colors-\(control.id)"),
            title: NSLocalizedString("滑块颜色", comment: "结构化控制滑块颜色向导上下文标题"),
            documents: [GuideDocumentReference(id: "model-request-body", title: "Request Body Controls")],
            settings: [
                .json(
                    "low_value_color",
                    label: NSLocalizedString("低值颜色", comment: "结构化控制滑块颜色向导字段"),
                    schema: GuideRequestBodyControlSettingsSupport.optionalColorSchema,
                    get: { .string(control.sliderStartColorHex ?? "") },
                    normalize: GuideRequestBodyControlSettingsSupport.normalizeOptionalColor,
                    set: { control.sliderStartColorHex = try GuideRequestBodyControlSettingsSupport.optionalColor(from: $0) }
                ),
                .json(
                    "high_value_color",
                    label: NSLocalizedString("高值颜色", comment: "结构化控制滑块颜色向导字段"),
                    schema: GuideRequestBodyControlSettingsSupport.optionalColorSchema,
                    get: { .string(control.sliderEndColorHex ?? "") },
                    normalize: GuideRequestBodyControlSettingsSupport.normalizeOptionalColor,
                    set: { control.sliderEndColorHex = try GuideRequestBodyControlSettingsSupport.optionalColor(from: $0) }
                ),
                .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: "向导设置字段"), value: { .string(NSLocalizedString("修改后需要保存模型", comment: "模型草稿应用方式")) })
            ]
        )
    }

    private var defaultPalette: RequestBodySliderPalette {
        RequestBodySliderPalette.defaultPalette(for: control)
    }

    private var resolvedPalette: RequestBodySliderPalette {
        RequestBodySliderPalette.resolved(for: control)
    }

    private var hasCustomColors: Bool {
        control.sliderStartColorHex != nil || control.sliderEndColorHex != nil
    }

    private func endpointColorBinding(
        _ keyPath: WritableKeyPath<ModelRequestBodyControl, String?>,
        position: Double
    ) -> Binding<Color> {
        Binding(
            get: {
                let fallback = defaultPalette.color(at: position)
                guard let hex = control[keyPath: keyPath] else { return fallback }
                return ChatAppearanceColorCodec.color(from: hex, fallback: fallback)
            },
            set: { color in
                guard let hex = ChatAppearanceColorCodec.hexRGBA(from: color) else { return }
                control[keyPath: keyPath] = hex
            }
        )
    }
}
