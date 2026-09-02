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
    @ObservedObject private var ttsServiceStore = TTSServiceStore.shared
    @StateObject private var guideRouter = GuideModelRouter()
    let isGuideContextActive: Bool

    init(isGuideContextActive: Bool = true) {
        self.isGuideContextActive = isGuideContextActive
    }

    var body: some View {
        Form {
            guideModelSection

            modelPickerSection(
                title: NSLocalizedString("语音模型", comment: "Speech model specialized selector title"),
                options: viewModel.speechModels,
                selectionID: speechModelIdentifierBinding,
                footer: NSLocalizedString("用于语音转文字；也可在“偏好设置”中修改。", comment: "Speech model specialized selector footer")
            )

            ttsServiceSection

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
        .guideSettingsPageContext(
            id: "settings-specialized-models",
            title: NSLocalizedString("专用模型", comment: "专用模型向导上下文标题"),
            documents: [GuideDocumentReference(id: "provider-model-basics", title: "Provider and Model Basics")],
            isActive: isGuideContextActive,
            settings: specializedModelGuideSettings
        )
        .onAppear {
            syncVideoAnalysisSelection()
            syncImageGenerationSelection()
        }
        .onChange(of: viewModel.activatedModelListVersion) { _, _ in
            syncVideoAnalysisSelection()
            syncImageGenerationSelection()
        }
    }

    private var specializedModelGuideSettings: [GuidePageSetting] {
        let guideModels = guideRouter.availableUserModels
        return [
            .string(
                "guide_route",
                label: NSLocalizedString("页面向导回答线路", comment: "专用模型向导字段"),
                allowedValues: GuideRoute.allCases.map(\.rawValue),
                allowsEmpty: false,
                get: { guideRouter.route.rawValue },
                set: { route in
                    if route == GuideRoute.builtIn.rawValue {
                        guideRouter.useBuiltIn()
                    } else if let selected = guideRouter.selectedUserModel {
                        guideRouter.selectUserModel(selected)
                    }
                }
            ),
            .string(
                "guide_model_id",
                label: NSLocalizedString("页面向导模型", comment: "专用模型向导字段"),
                allowedValues: [""] + guideModels.map(\.id),
                get: { guideRouter.selectedUserModel?.id ?? "" },
                set: { modelID in
                    guard let model = guideModels.first(where: { $0.id == modelID }) else { return }
                    guideRouter.selectUserModel(model)
                }
            ),
            guideModelSetting("speech_model_id", label: NSLocalizedString("语音模型", comment: "专用模型向导字段"), options: viewModel.speechModels, binding: speechModelIdentifierBinding),
            guideModelSetting("embedding_model_id", label: NSLocalizedString("嵌入模型", comment: "专用模型向导字段"), options: viewModel.embeddingModelOptions, binding: embeddingModelIdentifierBinding),
            guideModelSetting("title_model_id", label: NSLocalizedString("标题生成模型", comment: "专用模型向导字段"), options: viewModel.titleGenerationModelOptions, binding: titleModelIdentifierBinding),
            guideModelSetting("daily_pulse_model_id", label: NSLocalizedString("每日脉冲模型", comment: "专用模型向导字段"), options: viewModel.dailyPulseModelOptions, binding: dailyPulseModelIdentifierBinding),
            guideModelSetting("reasoning_summary_model_id", label: NSLocalizedString("思考摘要模型", comment: "专用模型向导字段"), options: viewModel.reasoningSummaryModelOptions, binding: reasoningSummaryModelIdentifierBinding),
            guideModelSetting("video_analysis_model_id", label: NSLocalizedString("视频解析模型", comment: "专用模型向导字段"), options: viewModel.videoAnalysisModelOptions, binding: videoAnalysisModelIdentifierBinding, allowsEmpty: false),
            guideModelSetting("ocr_model_id", label: NSLocalizedString("OCR 模型", comment: "专用模型向导字段"), options: viewModel.ocrModelOptions, binding: ocrModelIdentifierBinding, allowsEmpty: false),
            guideModelSetting("image_generation_model_id", label: NSLocalizedString("生图模型", comment: "专用模型向导字段"), options: viewModel.imageGenerationModelOptions, binding: imageGenerationModelIdentifierBinding, allowsEmpty: false),
            .readOnly(
                "tts_service",
                label: NSLocalizedString("TTS 服务", comment: "专用模型向导字段"),
                value: { .string(ttsServiceStore.selectedService?.name ?? "") }
            ),
            .readOnly(
                "available_guide_models",
                label: NSLocalizedString("可用页面向导模型", comment: "专用模型向导字段"),
                value: { runnableModelsValue(guideModels) }
            )
        ]
    }

    private func guideModelSetting(
        _ key: String,
        label: String,
        options: [RunnableModel],
        binding: Binding<String>,
        allowsEmpty: Bool = true
    ) -> GuidePageSetting {
        .string(
            key,
            label: label,
            allowedValues: (allowsEmpty ? [""] : []) + options.map(\.id),
            allowsEmpty: allowsEmpty,
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = $0 }
        )
    }

    private func runnableModelsValue(_ models: [RunnableModel]) -> JSONValue {
        .array(models.map { model in
            .dictionary([
                "id": .string(model.id),
                "name": .string(model.model.displayName),
                "provider": .string(model.provider.name),
                "model_name": .string(model.model.modelName)
            ])
        })
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

    private var ttsServiceSection: some View {
        Section {
            NavigationLink {
                TTSSettingsView()
            } label: {
                HStack {
                    Text(NSLocalizedString("TTS 服务", comment: "TTS 专用服务入口"))
                    Spacer()
                    Text(ttsServiceStore.selectedService?.name ?? NSLocalizedString("未配置", comment: ""))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } footer: {
            Text(NSLocalizedString("用于文字转语音；服务的添加、选择与编辑均在 TTS 设置中完成。", comment: "TTS 专用服务说明"))
        }
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
        .guideSettingsPageContext(
            id: "settings-guide-model-route",
            title: NSLocalizedString("页面向导模型", comment: "页面向导模型向导上下文标题"),
            documents: [GuideDocumentReference(id: "guide-overview", title: "Guide Overview")],
            settings: [
                .string(
                    "route",
                    label: NSLocalizedString("页面向导回答线路", comment: "专用模型向导字段"),
                    allowedValues: GuideRoute.allCases.map(\.rawValue),
                    allowsEmpty: false,
                    get: { router.route.rawValue },
                    set: { route in
                        if route == GuideRoute.builtIn.rawValue {
                            router.useBuiltIn()
                        } else if let selected = router.selectedUserModel {
                            router.selectUserModel(selected)
                        }
                    }
                ),
                .string(
                    "model_id",
                    label: NSLocalizedString("页面向导模型", comment: "专用模型向导字段"),
                    allowedValues: [""] + router.availableUserModels.map(\.id),
                    get: { router.selectedUserModel?.id ?? "" },
                    set: { modelID in
                        guard let model = router.availableUserModels.first(where: { $0.id == modelID }) else { return }
                        router.selectUserModel(model)
                    }
                )
            ]
        )
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
        .guideSettingsPageContext(
            id: "settings-specialized-model-selection",
            title: title,
            documents: [GuideDocumentReference(id: "provider-model-basics", title: "Provider and Model Basics")],
            settings: [
                .string(
                    "selected_model_id",
                    label: NSLocalizedString("当前模型", comment: "专用模型选择向导字段"),
                    allowedValues: (allowEmptySelection ? [""] : []) + options.map(\.id),
                    allowsEmpty: allowEmptySelection,
                    get: { selectionID.wrappedValue },
                    set: { selectionID.wrappedValue = $0 }
                ),
                .readOnly(
                    "available_models",
                    label: NSLocalizedString("可用模型", comment: "专用模型选择向导字段"),
                    value: {
                        .array(options.map { model in
                            .dictionary([
                                "id": .string(model.id),
                                "name": .string(model.model.displayName),
                                "provider": .string(model.provider.name),
                                "model_name": .string(model.model.modelName)
                            ])
                        })
                    }
                )
            ]
        )
    }

    private func select(_ identifier: String?) {
        selectionID.wrappedValue = identifier ?? ""
        dismiss()
    }
}
