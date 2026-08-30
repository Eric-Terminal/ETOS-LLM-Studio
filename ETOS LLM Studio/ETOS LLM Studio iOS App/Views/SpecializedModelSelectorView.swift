// ============================================================================
// SpecializedModelSelectorView.swift
// ============================================================================
// SpecializedModelSelectorView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import ETOSCore

struct SpecializedModelSelectorView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var appConfig = AppConfigStore.shared
    @StateObject private var guideRouter = GuideModelRouter()

    var body: some View {
        Form {
            guideModelSection

            modelPickerSection(
                title: NSLocalizedString("语音模型", comment: "Speech model specialized selector title"),
                options: viewModel.speechModels,
                selectionID: speechModelIdentifierBinding,
                footer: NSLocalizedString("用于语音转文字；也可在“偏好设置”中修改。", comment: "Speech model specialized selector footer")
            )

            modelPickerSection(
                title: NSLocalizedString("TTS 模型", comment: "TTS model specialized selector title"),
                options: viewModel.ttsModels,
                selectionID: ttsModelIdentifierBinding,
                allowEmptySelection: false,
                footer: NSLocalizedString("用于文字转语音；也可在“TTS 设置”中修改。", comment: "TTS model specialized selector footer")
            )

            modelPickerSection(
                title: NSLocalizedString("嵌入模型", comment: "Embedding model specialized selector title"),
                options: viewModel.embeddingModelOptions,
                selectionID: embeddingModelIdentifierBinding,
                footer: NSLocalizedString("用于记忆向量化与检索；也可在“记忆库管理”中修改。", comment: "Embedding model specialized selector footer")
            )

            modelPickerSection(
                title: NSLocalizedString("标题生成模型", comment: "Title generation model specialized selector title"),
                options: viewModel.titleGenerationModelOptions,
                selectionID: titleModelIdentifierBinding,
                footer: NSLocalizedString("留空时跟随当前对话模型。", comment: "Specialized selector empty follows chat model footer")
            )

            modelPickerSection(
                title: NSLocalizedString("每日脉冲模型", comment: "Daily pulse model specialized selector title"),
                options: viewModel.dailyPulseModelOptions,
                selectionID: dailyPulseModelIdentifierBinding,
                footer: NSLocalizedString("用于每日脉冲生成；留空时跟随当前对话模型。", comment: "Daily pulse model specialized selector footer")
            )

            modelPickerSection(
                title: NSLocalizedString("思考摘要模型", comment: "Reasoning summary model specialized selector title"),
                options: viewModel.reasoningSummaryModelOptions,
                selectionID: reasoningSummaryModelIdentifierBinding,
                footer: NSLocalizedString("用于为思考内容生成摘要；留空时跟随当前对话模型。", comment: "Reasoning summary model specialized selector footer")
            )

            modelPickerSection(
                title: NSLocalizedString("视频解析模型", comment: "Video analysis model specialized selector title"),
                options: viewModel.videoAnalysisModelOptions,
                selectionID: videoAnalysisModelIdentifierBinding,
                allowEmptySelection: false,
                footer: NSLocalizedString("用于先理解非原生视频并把解析文字交给当前对话模型。", comment: "Video analysis model specialized selector footer")
            )

            modelPickerSection(
                title: NSLocalizedString("OCR 模型", comment: "OCR model specialized selector title"),
                options: viewModel.ocrModelOptions,
                selectionID: ocrModelIdentifierBinding,
                allowEmptySelection: false,
                footer: NSLocalizedString("当当前对话模型不支持图片输入时，用于先把图片识别为文字；默认使用系统 OCR。", comment: "OCR model specialized selector footer")
            )

            modelPickerSection(
                title: NSLocalizedString("生图模型", comment: "Image generation model specialized selector title"),
                options: viewModel.imageGenerationModelOptions,
                selectionID: imageGenerationModelIdentifierBinding,
                allowEmptySelection: false,
                footer: NSLocalizedString("用于图片生成功能；也可在“图片生成”中修改。", comment: "Image generation model specialized selector footer")
            )
        }
        .navigationTitle(NSLocalizedString("专用模型选择器", comment: ""))
        .onAppear {
            syncVideoAnalysisSelection()
            syncImageGenerationSelection()
        }
        .onChange(of: viewModel.activatedModelListVersion) { _, _ in
            syncVideoAnalysisSelection()
            syncImageGenerationSelection()
        }
    }

    private var guideModelSection: some View {
        Section {
            NavigationLink {
                GuideModelRouteSelectionView(router: guideRouter)
            } label: {
                HStack {
                    Text(NSLocalizedString("页面向导模型", comment: "页面向导专用模型标题"))
                    MarqueeText(
                        content: selectedGuideModelLabel,
                        uiFont: .preferredFont(forTextStyle: .body)
                    )
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        } footer: {
            Text(NSLocalizedString("用于页面向导回答。内置免费向导始终可选；用户模型需要已启用并支持工具调用。", comment: "页面向导专用模型说明"))
        }
    }

    private var selectedGuideModelLabel: String {
        guard guideRouter.route == .userModel else {
            return NSLocalizedString("内置免费向导", comment: "内置向导线路名称")
        }
        guard let model = guideRouter.selectedUserModel else {
            return NSLocalizedString("不可用", comment: "专用模型失效状态")
        }
        return "\(model.model.displayName) | \(model.provider.name)"
    }

    private var speechModelIdentifierBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedSpeechModel?.id ?? "" },
            set: { newIdentifier in
                guard !newIdentifier.isEmpty else {
                    viewModel.setSelectedSpeechModel(nil)
                    return
                }
                let selected = viewModel.speechModels.first(where: { $0.id == newIdentifier })
                viewModel.setSelectedSpeechModel(selected)
            }
        )
    }

    private var embeddingModelIdentifierBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedEmbeddingModel?.id ?? "" },
            set: { newIdentifier in
                guard !newIdentifier.isEmpty else {
                    viewModel.setSelectedEmbeddingModel(nil)
                    return
                }
                let selected = viewModel.embeddingModelOptions.first(where: { $0.id == newIdentifier })
                viewModel.setSelectedEmbeddingModel(selected)
            }
        )
    }

    private var ttsModelIdentifierBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedTTSModel?.id ?? "" },
            set: { newIdentifier in
                guard !newIdentifier.isEmpty else {
                    viewModel.setSelectedTTSModel(nil)
                    return
                }
                let selected = viewModel.ttsModels.first(where: { $0.id == newIdentifier })
                viewModel.setSelectedTTSModel(selected)
            }
        )
    }

    private var titleModelIdentifierBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedTitleGenerationModel?.id ?? "" },
            set: { newIdentifier in
                guard !newIdentifier.isEmpty else {
                    viewModel.setSelectedTitleGenerationModel(nil)
                    return
                }
                let selected = viewModel.titleGenerationModelOptions.first(where: { $0.id == newIdentifier })
                viewModel.setSelectedTitleGenerationModel(selected)
            }
        )
    }

    private var dailyPulseModelIdentifierBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedDailyPulseModel?.id ?? "" },
            set: { newIdentifier in
                guard !newIdentifier.isEmpty else {
                    viewModel.setSelectedDailyPulseModel(nil)
                    return
                }
                let selected = viewModel.dailyPulseModelOptions.first(where: { $0.id == newIdentifier })
                viewModel.setSelectedDailyPulseModel(selected)
            }
        )
    }

    private var imageGenerationModelIdentifierBinding: Binding<String> {
        Binding(
            get: { appConfig.imageGenerationModelIdentifier },
            set: { setImageGenerationModelIdentifier($0) }
        )
    }

    private var reasoningSummaryModelIdentifierBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedReasoningSummaryModel?.id ?? "" },
            set: { newIdentifier in
                guard !newIdentifier.isEmpty else {
                    viewModel.setSelectedReasoningSummaryModel(nil)
                    return
                }
                let selected = viewModel.reasoningSummaryModelOptions.first(where: { $0.id == newIdentifier })
                viewModel.setSelectedReasoningSummaryModel(selected)
            }
        )
    }

    private var ocrModelIdentifierBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedOCRModel?.id ?? ChatService.systemOCRRunnableModel.id },
            set: { newIdentifier in
                let selected = viewModel.ocrModelOptions.first(where: { $0.id == newIdentifier })
                viewModel.setSelectedOCRModel(selected ?? ChatService.systemOCRRunnableModel)
            }
        )
    }

    private var videoAnalysisModelIdentifierBinding: Binding<String> {
        Binding(
            get: { appConfig.videoAnalysisModelIdentifier },
            set: { setVideoAnalysisModelIdentifier($0) }
        )
    }

    @ViewBuilder
    private func modelPickerSection(
        title: String,
        options: [RunnableModel],
        selectionID: Binding<String>,
        allowEmptySelection: Bool = true,
        footer: String
    ) -> some View {
        Section {
            if options.isEmpty {
                Text(NSLocalizedString("暂无可用模型，请先在提供商管理中启用。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink {
                    RunnableModelIdentifierSelectionView(
                        title: NSLocalizedString(title, comment: "专用模型选择标题"),
                        options: options,
                        selectionID: selectionID,
                        allowEmptySelection: allowEmptySelection
                    )
                } label: {
                    HStack {
                        Text(NSLocalizedString(title, comment: "专用模型入口标题"))
                        MarqueeText(
                            content: selectedModelLabel(
                                for: selectionID.wrappedValue,
                                in: options,
                                allowEmptySelection: allowEmptySelection
                            ),
                            uiFont: .preferredFont(forTextStyle: .body)
                        )
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        } footer: {
            Text(NSLocalizedString(footer, comment: "专用模型说明"))
        }
    }

    private func syncImageGenerationSelection() {
        let options = viewModel.imageGenerationModelOptions
        guard !options.isEmpty else {
            setImageGenerationModelIdentifier("")
            return
        }

        if let matched = viewModel.imageGenerationModel(with: appConfig.imageGenerationModelIdentifier) {
            setImageGenerationModelIdentifier(matched.id)
            return
        }

        setImageGenerationModelIdentifier(options[0].id)
    }

    private func syncVideoAnalysisSelection() {
        let options = viewModel.videoAnalysisModelOptions
        guard !options.isEmpty else {
            setVideoAnalysisModelIdentifier("")
            return
        }
        guard !options.contains(where: { $0.id == appConfig.videoAnalysisModelIdentifier }) else {
            return
        }
        setVideoAnalysisModelIdentifier(options[0].id)
    }

    private func setVideoAnalysisModelIdentifier(_ identifier: String) {
        AppConfigStore.persistSynchronously(.text(identifier), for: .videoAnalysisModelIdentifier)
        appConfig.videoAnalysisModelIdentifier = identifier
    }

    private func setImageGenerationModelIdentifier(_ identifier: String) {
        AppConfigStore.persistSynchronously(.text(identifier), for: .imageGenerationModelIdentifier)
        appConfig.imageGenerationModelIdentifier = identifier
    }

    private func selectedModelLabel(
        for selectionID: String,
        in options: [RunnableModel],
        allowEmptySelection: Bool
    ) -> String {
        if let matched = options.first(where: { $0.id == selectionID }) {
            return "\(matched.model.displayName) | \(matched.provider.name)"
        }

        if allowEmptySelection {
            return NSLocalizedString("未选择", comment: "")
        }

        return options.first.map { "\($0.model.displayName) | \($0.provider.name)" } ?? ""
    }
}

private struct GuideModelRouteSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var router: GuideModelRouter
    @ObservedObject private var appConfig = AppConfigStore.shared

    var body: some View {
        List {
            Section {
                Button {
                    router.useBuiltIn()
                    dismiss()
                } label: {
                    MarqueeTitleSubtitleSelectionRow(
                        title: NSLocalizedString("内置免费向导", comment: "内置向导线路名称"),
                        subtitle: NSLocalizedString("始终可用，不依赖你的模型配置", comment: "内置向导线路说明"),
                        isSelected: router.route == .builtIn,
                        subtitleUIFont: .preferredFont(forTextStyle: .caption1)
                    )
                }
            }

            Section(NSLocalizedString("使用我的模型", comment: "用户向导模型分组")) {
                if router.availableUserModels.isEmpty {
                    Text(NSLocalizedString("没有已启用且支持工具调用的云端聊天模型。仍可继续使用内置免费向导。", comment: "向导无用户模型说明"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(router.availableUserModels, id: \.id) { model in
                        Button {
                            router.selectUserModel(model)
                            dismiss()
                        } label: {
                            MarqueeTitleSubtitleSelectionRow(
                                title: model.model.displayName,
                                subtitle: "\(model.provider.name) · \(model.model.modelName)",
                                isSelected: router.route == .userModel &&
                                    appConfig.guidePreferredModelIdentifier == model.id,
                                subtitleUIFont: .monospacedSystemFont(
                                    ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                                    weight: .regular
                                )
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("页面向导模型", comment: "页面向导模型选择标题"))
    }
}

private struct RunnableModelIdentifierSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let options: [RunnableModel]
    let selectionID: Binding<String>
    let allowEmptySelection: Bool

    var body: some View {
        List {
            if allowEmptySelection {
                Button {
                    select(nil)
                } label: {
                    MarqueeSelectionRow(title: NSLocalizedString("未选择", comment: ""), isSelected: selectionID.wrappedValue.isEmpty)
                }
            }

            ForEach(options) { runnable in
                Button {
                    select(runnable.id)
                } label: {
                    MarqueeTitleSubtitleSelectionRow(
                        title: runnable.model.displayName,
                        subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                        isSelected: selectionID.wrappedValue == runnable.id,
                        subtitleUIFont: .monospacedSystemFont(
                            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                            weight: .regular
                        )
                    )
                }
            }
        }
        .navigationTitle(NSLocalizedString(title, comment: "专用模型选择标题"))
    }

    private func select(_ identifier: String?) {
        selectionID.wrappedValue = identifier ?? ""
        dismiss()
    }
}
