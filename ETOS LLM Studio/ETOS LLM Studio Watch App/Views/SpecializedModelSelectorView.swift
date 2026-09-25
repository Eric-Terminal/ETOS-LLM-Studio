// ============================================================================
// SpecializedModelSelectorView.swift
// ============================================================================
// SpecializedModelSelectorView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

import SwiftUI
import ETOSCore

struct SpecializedModelSelectorView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var ttsServiceStore = TTSServiceStore.shared
    @StateObject private var guideRouter = GuideModelRouter()

    private var speechModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedSpeechModel },
            set: { viewModel.setSelectedSpeechModel($0) }
        )
    }

    private var embeddingModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedEmbeddingModel },
            set: { viewModel.setSelectedEmbeddingModel($0) }
        )
    }

    private var titleModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedTitleGenerationModel },
            set: { viewModel.setSelectedTitleGenerationModel($0) }
        )
    }

    private var dailyPulseModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedDailyPulseModel },
            set: { viewModel.setSelectedDailyPulseModel($0) }
        )
    }

    private var reasoningSummaryModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedReasoningSummaryModel },
            set: { viewModel.setSelectedReasoningSummaryModel($0) }
        )
    }

    private var ocrModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedOCRModel },
            set: { viewModel.setSelectedOCRModel($0) }
        )
    }

    private var videoAnalysisModelBinding: Binding<RunnableModel?> {
        Binding(
            get: {
                viewModel.videoAnalysisModelOptions.first {
                    $0.id == appConfig.videoAnalysisModelIdentifier
                }
            },
            set: { setVideoAnalysisModelIdentifier($0?.id ?? "") }
        )
    }

    private var imageGenerationModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.imageGenerationModel(with: appConfig.imageGenerationModelIdentifier) },
            set: { setImageGenerationModelIdentifier($0?.id ?? "") }
        )
    }

    var body: some View {
        List {
            guideModelSection

            modelSelectionSection(
                title: NSLocalizedString("语音模型", comment: "Speech model specialized selector title"),
                options: viewModel.speechModels,
                selection: speechModelBinding,
                footer: NSLocalizedString("用于语音转文字，也可在偏好设置中修改。", comment: "Watch speech model specialized selector footer")
            )

            ttsServiceSection

            modelSelectionSection(
                title: NSLocalizedString("嵌入模型", comment: "Embedding model specialized selector title"),
                options: viewModel.embeddingModelOptions,
                selection: embeddingModelBinding,
                footer: NSLocalizedString("用于记忆嵌入，也可在记忆库管理中修改。", comment: "Watch embedding model specialized selector footer")
            )

            modelSelectionSection(
                title: NSLocalizedString("标题生成模型", comment: "Title generation model specialized selector title"),
                options: viewModel.titleGenerationModelOptions,
                selection: titleModelBinding,
                footer: NSLocalizedString("留空时跟随当前对话模型。", comment: "Specialized selector empty follows chat model footer")
            )

            modelSelectionSection(
                title: NSLocalizedString("每日脉冲模型", comment: "Daily pulse model specialized selector title"),
                options: viewModel.dailyPulseModelOptions,
                selection: dailyPulseModelBinding,
                footer: NSLocalizedString("用于每日脉冲生成；留空时跟随当前对话模型。", comment: "Daily pulse model specialized selector footer")
            )

            modelSelectionSection(
                title: NSLocalizedString("思考摘要模型", comment: "Reasoning summary model specialized selector title"),
                options: viewModel.reasoningSummaryModelOptions,
                selection: reasoningSummaryModelBinding,
                footer: NSLocalizedString("用于为思考内容生成摘要；留空时跟随当前对话模型。", comment: "Reasoning summary model specialized selector footer")
            )

            modelSelectionSection(
                title: NSLocalizedString("视频解析模型", comment: "Video analysis model specialized selector title"),
                options: viewModel.videoAnalysisModelOptions,
                selection: videoAnalysisModelBinding,
                allowEmptySelection: false,
                footer: NSLocalizedString("用于先理解非原生视频并把解析文字交给当前对话模型。", comment: "Video analysis model specialized selector footer")
            )

            modelSelectionSection(
                title: NSLocalizedString("OCR 模型", comment: "OCR model specialized selector title"),
                options: viewModel.ocrModelOptions,
                selection: ocrModelBinding,
                footer: NSLocalizedString("当前对话模型不支持图片输入时，用于先把图片识别为文字；手表端默认不选择。", comment: "Watch OCR model specialized selector footer")
            )

            modelSelectionSection(
                title: NSLocalizedString("生图模型", comment: "Image generation model specialized selector title"),
                options: viewModel.imageGenerationModelOptions,
                selection: imageGenerationModelBinding,
                allowEmptySelection: false,
                footer: NSLocalizedString("用于图片生成，也可在图片生成功能中修改。", comment: "Watch image generation model specialized selector footer")
            )
        }
        .navigationTitle(NSLocalizedString("专用模型", comment: ""))
        .guideSettingsPageContext(
            id: "settings-specialized-models",
            title: NSLocalizedString("专用模型", comment: "专用模型向导上下文标题"),
            documents: [GuideDocumentReference(id: "provider-model-basics", title: "Provider and Model Basics")],
            settings: specializedModelGuideSettings
        )
        .watchGuideEntry()
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
            guideModelSetting("speech_model_id", label: NSLocalizedString("语音模型", comment: "专用模型向导字段"), options: viewModel.speechModels, selection: speechModelBinding),
            guideModelSetting("embedding_model_id", label: NSLocalizedString("嵌入模型", comment: "专用模型向导字段"), options: viewModel.embeddingModelOptions, selection: embeddingModelBinding),
            guideModelSetting("title_model_id", label: NSLocalizedString("标题生成模型", comment: "专用模型向导字段"), options: viewModel.titleGenerationModelOptions, selection: titleModelBinding),
            guideModelSetting("daily_pulse_model_id", label: NSLocalizedString("每日脉冲模型", comment: "专用模型向导字段"), options: viewModel.dailyPulseModelOptions, selection: dailyPulseModelBinding),
            guideModelSetting("reasoning_summary_model_id", label: NSLocalizedString("思考摘要模型", comment: "专用模型向导字段"), options: viewModel.reasoningSummaryModelOptions, selection: reasoningSummaryModelBinding),
            guideModelSetting("video_analysis_model_id", label: NSLocalizedString("视频解析模型", comment: "专用模型向导字段"), options: viewModel.videoAnalysisModelOptions, selection: videoAnalysisModelBinding, allowsEmpty: false),
            guideModelSetting("ocr_model_id", label: NSLocalizedString("OCR 模型", comment: "专用模型向导字段"), options: viewModel.ocrModelOptions, selection: ocrModelBinding),
            guideModelSetting("image_generation_model_id", label: NSLocalizedString("生图模型", comment: "专用模型向导字段"), options: viewModel.imageGenerationModelOptions, selection: imageGenerationModelBinding, allowsEmpty: false),
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
        selection: Binding<RunnableModel?>,
        allowsEmpty: Bool = true
    ) -> GuidePageSetting {
        .string(
            key,
            label: label,
            allowedValues: (allowsEmpty ? [""] : []) + options.map(\.id),
            allowsEmpty: allowsEmpty,
            get: { selection.wrappedValue?.id ?? "" },
            set: { modelID in
                selection.wrappedValue = options.first(where: { $0.id == modelID })
            }
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
                WatchGuideModelRouteSelectionView(router: guideRouter)
            } label: {
                HStack {
                    Text(NSLocalizedString("页面向导模型", comment: "页面向导专用模型标题"))
                    Spacer()
                    MarqueeText(
                        content: selectedGuideModelLabel,
                        uiFont: .preferredFont(forTextStyle: .footnote)
                    )
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        } footer: {
            Text(NSLocalizedString("用于页面向导回答。内置免费向导始终可选；用户模型需要已启用并支持工具调用。", comment: "页面向导专用模型说明"))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var ttsServiceSection: some View {
        Section {
            NavigationLink {
                TTSSettingsView()
            } label: {
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("TTS 服务", comment: "TTS 专用服务入口"))
                    Text(ttsServiceStore.selectedService?.name ?? NSLocalizedString("未配置", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } footer: {
            Text(NSLocalizedString("用于文字转语音；添加、选择与编辑均在 TTS 设置中完成。", comment: "watchOS TTS 专用服务说明"))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
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

    @ViewBuilder
    private func modelSelectionSection(
        title: String,
        options: [RunnableModel],
        selection: Binding<RunnableModel?>,
        allowEmptySelection: Bool = true,
        footer: String
    ) -> some View {
        Section {
            if options.isEmpty {
                Text(NSLocalizedString("暂无可用模型，请先启用。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink {
                    WatchRunnableModelSelectionListView(
                        title: NSLocalizedString(title, comment: "专用模型选择标题"),
                        models: options,
                        selectedModel: selection,
                        allowEmptySelection: allowEmptySelection
                    )
                } label: {
                    HStack {
                        Text(NSLocalizedString(title, comment: "专用模型入口标题"))
                        Spacer()
                        MarqueeText(
                            content: selectedModelLabel(selection.wrappedValue, in: options),
                            uiFont: .preferredFont(forTextStyle: .footnote)
                        )
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        } footer: {
            Text(NSLocalizedString(footer, comment: "专用模型说明"))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func selectedModelLabel(_ selection: RunnableModel?, in options: [RunnableModel]) -> String {
        guard let selection,
              options.contains(where: { $0.id == selection.id }) else {
            return NSLocalizedString("未选择", comment: "")
        }
        return "\(selection.model.displayName) | \(selection.provider.name)"
    }

    private func syncImageGenerationSelection() {
        guard !appConfig.imageGenerationModelIdentifier.isEmpty else { return }
        if viewModel.imageGenerationModel(with: appConfig.imageGenerationModelIdentifier) == nil {
            setImageGenerationModelIdentifier("")
        }
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
}

struct WatchGuideModelRouteSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var router: GuideModelRouter
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var selectedProviderID: UUID?
    @State private var showsAllModels = false

    let preservesSourceContext: Bool

    init(router: GuideModelRouter, preservesSourceContext: Bool = false) {
        self.router = router
        self.preservesSourceContext = preservesSourceContext
        _selectedProviderID = State(
            initialValue: router.selectedUserModel?.provider.id ?? router.modelOptions.providerGroups.first?.id
        )
    }

    var body: some View {
        if preservesSourceContext {
            // 对话内切换回答模型仍属于原来的求助过程，不替换来源页或递归打开向导。
            modelList
        } else {
            modelList
                .guideSettingsPageContext(
                    id: "settings-guide-model-route",
                    title: NSLocalizedString("页面向导模型", comment: "页面向导模型向导上下文标题"),
                    documents: [GuideDocumentReference(id: "guide-overview", title: "Guide Overview")],
                    settings: guideSettings
                )
                .watchGuideEntry()
        }
    }

    private var modelList: some View {
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
                        subtitleUIFont: .preferredFont(forTextStyle: .caption2)
                    )
                }
            }

            if router.availableUserModels.isEmpty {
                Section(NSLocalizedString("使用我的模型", comment: "用户向导模型分组")) {
                    Text(NSLocalizedString("没有已启用且支持工具调用的云端聊天模型。仍可继续使用内置免费向导。", comment: "向导无用户模型说明"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if appConfig.watchModelPickerGroupsByProvider && !showsAllModels {
                Section(NSLocalizedString("提供商", comment: "向导模型提供商分组")) {
                    Picker(NSLocalizedString("提供商", comment: "向导模型提供商选择"), selection: $selectedProviderID) {
                        ForEach(router.modelOptions.providerGroups) { group in
                            Text(group.provider.name).tag(Optional(group.id))
                        }
                    }
                }
                if let selectedProviderID,
                   let group = router.modelOptions.groupsByProviderID[selectedProviderID] {
                    Section(NSLocalizedString("使用我的模型", comment: "用户向导模型分组")) {
                        modelTreeRows(group.pickerLayout.rootItems)
                    }
                }
                Section {
                    Button {
                        showsAllModels = true
                    } label: {
                        Label(NSLocalizedString("全部模型", comment: "显示全部向导模型"), systemImage: "square.grid.2x2")
                    }
                }
            } else {
                Section(NSLocalizedString("使用我的模型", comment: "用户向导模型分组")) {
                    ForEach(router.availableUserModels) { model in
                        modelButton(model)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("页面向导模型", comment: "页面向导模型选择标题"))
        .onReceive(router.$modelOptions) { options in
            syncSelectedProvider(options)
        }
    }

    private var guideSettings: [GuidePageSetting] {
        [
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
                allowedValues: router.modelOptions.modelIDsAllowingNone,
                get: { router.selectedUserModel?.id ?? "" },
                set: { modelID in
                    guard let model = router.modelOptions.modelsByID[modelID] else { return }
                    router.selectUserModel(model)
                }
            )
        ]
    }

    private func syncSelectedProvider(_ options: GuideModelOptions) {
        if let selectedProviderID, options.groupsByProviderID[selectedProviderID] != nil { return }
        selectedProviderID = options.modelsByID[appConfig.guidePreferredModelIdentifier]?.provider.id
            ?? options.providerGroups.first?.id
    }

    private func modelTreeRows(_ items: [RunnableModelPickerRootItem]) -> AnyView {
        AnyView(ForEach(items) { item in
            switch item {
            case .model(let model):
                modelButton(model)
            case .group(let group):
                let isExpanded = appConfig.watchModelPickerExpandedGroupIDs.contains(group.id)
                Button {
                    if isExpanded {
                        appConfig.watchModelPickerExpandedGroupIDs.remove(group.id)
                    } else {
                        appConfig.watchModelPickerExpandedGroupIDs.insert(group.id)
                    }
                } label: {
                    Label(group.name, systemImage: isExpanded ? "folder.fill" : "folder")
                }
                .buttonStyle(.plain)
                if isExpanded {
                    modelTreeRows(group.items)
                }
            }
        })
    }

    private func modelButton(_ model: RunnableModel) -> some View {
        Button {
            router.selectUserModel(model)
            dismiss()
        } label: {
            MarqueeTitleSubtitleSelectionRow(
                title: model.model.displayName,
                subtitle: "\(model.provider.name) · \(model.model.modelName)",
                isSelected: router.route == .userModel && appConfig.guidePreferredModelIdentifier == model.id,
                subtitleUIFont: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                    weight: .regular
                )
            )
        }
    }
}

private struct WatchRunnableModelSelectionListView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let models: [RunnableModel]
    @Binding var selectedModel: RunnableModel?
    let allowEmptySelection: Bool

    var body: some View {
        List {
            if allowEmptySelection {
                Button {
                    select(nil)
                } label: {
                    selectionRow(title: NSLocalizedString("未选择", comment: ""), isSelected: selectedModel == nil)
                }
            }

            ForEach(models) { runnable in
                Button {
                    select(runnable)
                } label: {
                    selectionRow(
                        title: runnable.model.displayName,
                        subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                        isSelected: selectedModel?.id == runnable.id
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
                    allowedValues: (allowEmptySelection ? [""] : []) + models.map(\.id),
                    allowsEmpty: allowEmptySelection,
                    get: { selectedModel?.id ?? "" },
                    set: { modelID in selectedModel = models.first(where: { $0.id == modelID }) }
                ),
                .readOnly(
                    "available_models",
                    label: NSLocalizedString("可用模型", comment: "专用模型选择向导字段"),
                    value: {
                        .array(models.map { model in
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
        .watchGuideEntry()
    }

    private func select(_ model: RunnableModel?) {
        selectedModel = model
        dismiss()
    }

    @ViewBuilder
    private func selectionRow(title: String, subtitle: String? = nil, isSelected: Bool) -> some View {
        MarqueeTitleSubtitleSelectionRow(
            title: title,
            subtitle: subtitle,
            isSelected: isSelected,
            subtitleUIFont: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                weight: .regular
            )
        )
    }
}
