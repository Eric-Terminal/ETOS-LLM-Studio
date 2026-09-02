// ============================================================================
// ModelAdvancedSettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 偏好设置视图
//
// 功能特性:
// - 调整 Temperature, Top P, System Prompt 等参数
// - 管理上下文和懒加载数量
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

enum ModelAdvancedSettingsDestination: Hashable {
    case conversation
    case prompts
    case output

    var title: String {
        switch self {
        case .conversation:
            return NSLocalizedString("会话", comment: "Core conversation settings title")
        case .prompts:
            return NSLocalizedString("提示词", comment: "Core prompt settings title")
        case .output:
            return NSLocalizedString("输出", comment: "Core output settings title")
        }
    }
}

/// 按用户目标拆分后的核心设置视图。
struct ModelAdvancedSettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var contextCompressionReminderThresholdDraft: String = ""
    @State private var isEditingContextCompressionReminderThreshold = false
    @State private var isShowingSettingsIntro = false

    // MARK: - 绑定

    @Binding var aiTemperature: Double
    @Binding var aiTopP: Double
    @Binding var aiTemperatureEnabled: Bool
    @Binding var aiTopPEnabled: Bool
    @Binding var globalSystemPromptEntries: [GlobalSystemPromptEntry]
    @Binding var selectedGlobalSystemPromptEntryID: UUID?
    @Binding var maxChatHistory: Int
    @Binding var lazyLoadMessageCount: Int
    @Binding var enableStreaming: Bool
    @Binding var enableResponseSpeedMetrics: Bool
    @Binding var enableOpenAIStreamIncludeUsage: Bool
    @Binding var enableAutoSessionNaming: Bool
    @Binding var enableReasoningSummary: Bool
    @Binding var currentSession: ChatSession?
    @Binding var includeSystemTimeInPrompt: Bool
    @Binding var systemTimeInjectionPosition: SystemTimeInjectionPosition
    @Binding var enablePeriodicTimeLandmark: Bool
    @Binding var periodicTimeLandmarkIntervalMinutes: Int

    let addGlobalSystemPromptEntry: () -> Void
    let selectGlobalSystemPromptEntry: (UUID?) -> Void
    let updateSelectedGlobalSystemPromptContent: (String) -> Void
    let updateGlobalSystemPromptEntry: (UUID, String, String) -> Void
    let deleteGlobalSystemPromptEntry: (UUID) -> Void
    let destination: ModelAdvancedSettingsDestination

    private let samplingParameterStep = 0.01
    private let temperatureRange = 0.0...2.0
    private let topPRange = 0.0...1.0

    // MARK: - 私有属性

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private var samplingParameterFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.minimumIntegerDigits = 1
        return formatter
    }

    private var sendDelayFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.minimumIntegerDigits = 1
        return formatter
    }

    private var selectedGlobalPromptEntry: GlobalSystemPromptEntry? {
        guard let selectedGlobalSystemPromptEntryID else { return nil }
        return globalSystemPromptEntries.first(where: { $0.id == selectedGlobalSystemPromptEntryID })
    }

    private var selectedGlobalPromptContentBinding: Binding<String> {
        Binding(
            get: { selectedGlobalPromptEntry?.content ?? "" },
            set: { updateSelectedGlobalSystemPromptContent($0) }
        )
    }

    // MARK: - 视图主体

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: destination.title,
                    summary: settingsIntroSummary,
                    details: settingsIntroDetails,
                    isExpanded: $isShowingSettingsIntro
                )
            }

            if destination == .prompts {
                Section {
                    Toggle(
                        NSLocalizedString("在模型选择器中显示提示词", comment: "Show prompt shortcut in model picker"),
                        isOn: $appConfig.modelPickerPromptShortcutEnabled
                    )
                } footer: {
                    Text(NSLocalizedString("开启后，可从模型选择器快速编辑系统、话题与增强提示词。", comment: "Prompt shortcut setting description"))
                }

                Section(header: Text(NSLocalizedString("全局系统提示词", comment: ""))) {
                TextField(NSLocalizedString("自定义全局系统提示词", comment: ""), text: selectedGlobalPromptContentBinding.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(5...10)
                    .disabled(selectedGlobalPromptEntry == nil)

                NavigationLink {
                    GlobalSystemPromptPickerView(
                        entries: globalSystemPromptEntries,
                        selectedEntryID: selectedGlobalSystemPromptEntryID,
                        addGlobalSystemPromptEntry: addGlobalSystemPromptEntry,
                        selectGlobalSystemPromptEntry: selectGlobalSystemPromptEntry,
                        updateGlobalSystemPromptEntry: updateGlobalSystemPromptEntry,
                        deleteGlobalSystemPromptEntry: deleteGlobalSystemPromptEntry
                    )
                } label: {
                    HStack {
                        Text(NSLocalizedString("提示词列表", comment: ""))
                        Spacer()
                        Text(displayTitle(for: selectedGlobalPromptEntry))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Section(header: Text(NSLocalizedString("当前话题提示词", comment: "")), footer: Text(NSLocalizedString("仅对当前对话生效。", comment: ""))) {
                TextField(NSLocalizedString("自定义话题提示词", comment: ""), text: Binding(
                    get: { currentSession?.topicPrompt ?? "" },
                    set: { newValue in
                        if var session = currentSession {
                            session.topicPrompt = newValue
                            currentSession = session
                            ChatService.shared.updateSession(session)
                        }
                    }
                ).watchKeyboardNewlineBinding(), axis: .vertical)
                .lineLimit(3...8)
            }

            Section {
                TextField(NSLocalizedString("自定义增强提示词", comment: ""), text: Binding(
                    get: { currentSession?.enhancedPrompt ?? "" },
                    set: { newValue in
                        if var session = currentSession {
                            session.enhancedPrompt = newValue
                            currentSession = session
                            ChatService.shared.updateSession(session)
                        }
                    }
                ).watchKeyboardNewlineBinding(), axis: .vertical)
                .lineLimit(3...8)
                Toggle(
                    NSLocalizedString("使用 System 角色发送", comment: "OpenAI enhanced prompt role toggle"),
                    isOn: $appConfig.openAITailContextUsesSystemRole
                )
            } header: {
                Text(NSLocalizedString("增强提示词", comment: ""))
            } footer: {
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("该提示词会附加在您的最后一条消息末尾，以增强指令效果。", comment: ""))
                    Text(NSLocalizedString("角色设置仅对 OpenAI 适配器生效。", comment: "OpenAI enhanced prompt role footer"))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

                Section(header: Text(NSLocalizedString("动态时间注入", comment: ""))) {
                    Toggle(NSLocalizedString("发送系统时间", comment: ""), isOn: $includeSystemTimeInPrompt)
                    if includeSystemTimeInPrompt {
                        Picker(NSLocalizedString("发送位置", comment: ""), selection: $systemTimeInjectionPosition) {
                            ForEach(SystemTimeInjectionPosition.allCases) { position in
                                Text(position.displayName).tag(position)
                            }
                        }
                    }
                    Toggle(NSLocalizedString("周期性时间路标", comment: ""), isOn: $enablePeriodicTimeLandmark)
                    TextField(
                        NSLocalizedString("路标时间（分钟）", comment: ""),
                        value: $periodicTimeLandmarkIntervalMinutes,
                        formatter: numberFormatter
                    )
                    .disabled(!enablePeriodicTimeLandmark)
                }

                Section(header: Text(NSLocalizedString("内置提示词", comment: "Built-in prompt settings section"))) {
                    NavigationLink {
                        BuiltInPromptSettingsView()
                    } label: {
                        Label(NSLocalizedString("提示词模板", comment: "Built-in prompt settings entry"), systemImage: "curlybraces")
                    }
                }
            }

            if destination == .conversation {
                Section(header: Text(NSLocalizedString("消息规则", comment: ""))) {
                    NavigationLink {
                        MessageRegexRulesView()
                    } label: {
                        Label(NSLocalizedString("正则替换", comment: ""), systemImage: "textformat")
                    }
                }

                Section(header: Text(NSLocalizedString("启动与发送", comment: "Conversation launch and send settings section"))) {
                    LaunchSessionSettingsRows()
                    Toggle(NSLocalizedString("自动生成话题标题", comment: ""), isOn: $enableAutoSessionNaming)
                    HStack {
                        Text(NSLocalizedString("延迟发送（秒）", comment: "Send delay seconds setting title"))
                        Spacer()
                        TextField(NSLocalizedString("秒", comment: "Seconds placeholder"), value: sendDelayBinding, formatter: sendDelayFormatter)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 60)
                    }
                }

                Section(
                    header: Text(NSLocalizedString("会话协作", comment: "Conversation collaboration settings")),
                    footer: Text(NSLocalizedString("自动执行预算由同一根协作链共享，耗尽后可从会话列表继续。", comment: "Watch conversation runtime settings explanation"))
                ) {
                    TextField(
                        NSLocalizedString("自动执行预算", comment: "Conversation runtime execution budget"),
                        value: conversationRuntimeBudgetBinding,
                        formatter: numberFormatter
                    )
                    .monospacedDigit()
                }

                Section(
                    header: Text(NSLocalizedString("上下文窗口管理", comment: "")),
                    footer: Text(NSLocalizedString("开启后会在接近边缘时自动加载并回收历史气泡。关闭后按设置显示最近消息，每次向上加载 5 条；回到底部时恢复初始范围。设为 0 时显示全部历史。", comment: "自动管理聊天历史窗口说明"))
                ) {
                    HStack {
                        Text(NSLocalizedString("最大上下文消息数", comment: ""))
                        Spacer()
                        TextField(NSLocalizedString("数量", comment: ""), value: $maxChatHistory, formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }

                    Toggle(
                        NSLocalizedString("自动管理历史消息", comment: "自动管理聊天历史窗口设置"),
                        isOn: $viewModel.automaticHistoryLoadingEnabled
                    )

                    if !viewModel.automaticHistoryLoadingEnabled {
                        HStack {
                            Text(NSLocalizedString("初始显示消息数", comment: "手动模式初始显示聊天消息数设置"))
                            Spacer()
                            TextField(NSLocalizedString("数量", comment: ""), value: $lazyLoadMessageCount, formatter: numberFormatter)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                        }
                    }

                    Toggle(
                        NSLocalizedString("上下文压缩提醒", comment: "Context compression reminder toggle"),
                        isOn: $appConfig.enableContextCompressionReminder
                    )

                    if appConfig.enableContextCompressionReminder {
                        TextField(
                            NSLocalizedString("提醒阈值（Token）", comment: "Context compression reminder token threshold"),
                            text: $contextCompressionReminderThresholdDraft,
                            onEditingChanged: { isEditing in
                                isEditingContextCompressionReminderThreshold = isEditing
                                if !isEditing {
                                    commitContextCompressionReminderThresholdDraft()
                                }
                            },
                            onCommit: commitContextCompressionReminderThresholdDraft
                        )
                        .monospacedDigit()
                    }
                }

                Section {
                    Toggle(
                        NSLocalizedString("非原生视频使用解析模型", comment: "Use video analysis model toggle"),
                        isOn: $appConfig.enableVideoAnalysisForNonNativeModels
                    )

                    if appConfig.enableVideoAnalysisForNonNativeModels {
                        if viewModel.videoAnalysisModelOptions.isEmpty {
                            Text(NSLocalizedString("暂无支持原生视频输入的可用模型。", comment: "No video analysis model available"))
                                .etFont(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker(
                                NSLocalizedString("视频解析模型", comment: "Video analysis model picker"),
                                selection: videoAnalysisModelIdentifierBinding
                            ) {
                                ForEach(viewModel.videoAnalysisModelOptions) { model in
                                    Text("\(model.model.displayName) | \(model.provider.name)")
                                        .tag(model.id)
                                }
                            }
                        }
                    }

                    Picker(
                        NSLocalizedString("视频处理方式", comment: "Video processing mode setting"),
                        selection: videoFrameExtractionModeBinding
                    ) {
                        ForEach(VideoFrameExtractionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    if videoFrameExtractionModeBinding.wrappedValue == .fixedFPS {
                        samplingParameterField(
                            title: NSLocalizedString("抽帧 FPS", comment: "Video extraction FPS"),
                            value: videoFrameExtractionFPSBinding
                        )
                    }

                    HStack {
                        Text(NSLocalizedString("最多画面数", comment: "Maximum extracted video frames"))
                        Spacer()
                        TextField(
                            NSLocalizedString("数量", comment: "Maximum extracted video frames field placeholder"),
                            value: videoFrameMaximumCountBinding,
                            formatter: numberFormatter
                        )
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 64)
                        .accessibilityLabel(Text(NSLocalizedString(
                            "最多画面数",
                            comment: "Maximum extracted video frames"
                        )))
                    }
                } header: {
                    Text(NSLocalizedString("视频发送", comment: "Video sending settings section"))
                } footer: {
                    Text(NSLocalizedString(
                        "开启后，非原生视频会先解析并保存文字，再交给当前对话模型；关闭时继续使用抽帧方式。原生视频模型仍直接接收视频。",
                        comment: "Watch video sending settings explanation"
                    ))
                }

                Section {
                    NavigationLink(destination: WatchKeyboardSettingsView()) {
                        Label(NSLocalizedString("键盘", comment: "Keyboard settings title"), systemImage: "keyboard")
                    }
                }
            }

            if destination == .output {
                Section(header: Text(NSLocalizedString("采样参数", comment: ""))) {
                    Toggle(NSLocalizedString("自定义 Temperature", comment: ""), isOn: $aiTemperatureEnabled)
                    if aiTemperatureEnabled {
                        NavigationLink {
                            WatchTemperatureSliderView(value: temperatureBinding)
                        } label: {
                            HStack {
                                Text(NSLocalizedString("温度", comment: "Temperature sampling parameter title"))
                                Spacer()
                                Text(temperatureDisplayValue)
                                    .monospacedDigit()
                                    .foregroundStyle(
                                        WatchRequestBodySliderPalette.temperature.color(at: temperatureSliderPosition)
                                    )
                            }
                        }
                    }

                    Toggle(NSLocalizedString("自定义 Top P", comment: ""), isOn: $aiTopPEnabled)
                    if aiTopPEnabled {
                        samplingParameterField(
                            title: NSLocalizedString("Top-P", comment: "Top P sampling parameter title"),
                            value: topPBinding
                        )
                    }
                }

                Section(header: Text(NSLocalizedString("流式输出", comment: ""))) {
                    Toggle(NSLocalizedString("启用流式输出", comment: ""), isOn: $enableStreaming)
                    Toggle(NSLocalizedString("流式附带官方 Token 用量", comment: "Enable stream include usage in OpenAI-compatible requests"), isOn: $enableOpenAIStreamIncludeUsage)
                }

                Section(
                    header: Text(NSLocalizedString("思考与推理", comment: "Output reasoning settings section")),
                    footer: reasoningContentEchoFooter
                ) {
                    Toggle(NSLocalizedString("启用思考摘要", comment: ""), isOn: $enableReasoningSummary)
                    Picker(NSLocalizedString("思维链回传", comment: ""), selection: reasoningContentEchoModeBinding) {
                        ForEach(ReasoningContentEchoMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                Section(header: Text(NSLocalizedString("响应测速与统计", comment: "Response speed metrics section title"))) {
                    Toggle(NSLocalizedString("启用响应测速", comment: "Enable response speed metrics"), isOn: $enableResponseSpeedMetrics)
                }

                Section(header: Text(NSLocalizedString("语音朗读", comment: "TTS output settings section"))) {
                    NavigationLink {
                        TTSSettingsView()
                            .environmentObject(viewModel)
                    } label: {
                        Label(NSLocalizedString("语音朗读（TTS）", comment: ""), systemImage: "speaker.wave.2")
                    }
                }
            }
        }
        .navigationTitle(destination.title)
        .onAppear {
            syncContextCompressionReminderThresholdDraft()
            normalizeSamplingParametersIfNeeded()
            syncVideoAnalysisModelSelection()
        }
        .onChange(of: appConfig.contextCompressionReminderTokenThreshold) { _, _ in
            if !isEditingContextCompressionReminderThreshold {
                syncContextCompressionReminderThresholdDraft()
            }
        }
        .onChange(of: appConfig.enableContextCompressionReminder) { _, isEnabled in
            if !isEnabled {
                commitContextCompressionReminderThresholdDraft()
            }
        }
        .onChange(of: appConfig.enableVideoAnalysisForNonNativeModels) { _, isEnabled in
            if isEnabled {
                syncVideoAnalysisModelSelection()
            }
        }
        .onChange(of: viewModel.activatedModelListVersion) { _, _ in
            syncVideoAnalysisModelSelection()
        }
        .onChange(of: periodicTimeLandmarkIntervalMinutes) { _, newValue in
            if newValue < 1 {
                periodicTimeLandmarkIntervalMinutes = 1
            }
        }
        .onDisappear(perform: commitContextCompressionReminderThresholdDraft)
        .guideSettingsPageContext(
            id: guidePageID,
            title: destination.title,
            documents: [GuideDocumentReference(id: "settings-core", title: "Core Settings")],
            settings: guideSettings
        )
        .watchGuideEntry()
    }

    private var guidePageID: GuidePageID {
        switch destination {
        case .conversation: return "settings-conversation"
        case .prompts: return "settings-prompts"
        case .output: return "settings-output"
        }
    }

    private var guideSettings: [GuidePageSetting] {
        switch destination {
        case .conversation: return conversationGuideSettings
        case .prompts: return promptGuideSettings
        case .output: return outputGuideSettings
        }
    }

    private var conversationGuideSettings: [GuidePageSetting] {
        var settings: [GuidePageSetting] = [
            .bool("auto_session_naming", label: NSLocalizedString("自动生成话题标题", comment: "向导设置字段"), get: { enableAutoSessionNaming }, set: { enableAutoSessionNaming = $0 }),
            .double("send_delay_seconds", label: NSLocalizedString("延迟发送秒数", comment: "向导设置字段"), range: 0...3_600, get: { normalizedSendDelay(appConfig.chatSendDelaySeconds) }, set: { appConfig.chatSendDelaySeconds = normalizedSendDelay($0) }),
            .integer("automatic_execution_budget", label: NSLocalizedString("自动执行预算", comment: "向导设置字段"), range: 1...10_000, get: { max(1, appConfig.conversationRuntimeExecutionBudget) }, set: { appConfig.conversationRuntimeExecutionBudget = max(1, $0) }),
            .integer("max_context_messages", label: NSLocalizedString("最大上下文消息数", comment: "向导设置字段"), range: 1...100_000, get: { maxChatHistory }, set: { maxChatHistory = $0 }),
            .bool("automatic_history_loading", label: NSLocalizedString("自动管理历史消息", comment: "向导设置字段"), get: { viewModel.automaticHistoryLoadingEnabled }, set: { viewModel.automaticHistoryLoadingEnabled = $0 }),
            .bool("context_compression_reminder", label: NSLocalizedString("上下文压缩提醒", comment: "向导设置字段"), get: { appConfig.enableContextCompressionReminder }, set: { appConfig.enableContextCompressionReminder = $0 }),
            .integer("context_compression_token_threshold", label: NSLocalizedString("上下文压缩提醒阈值", comment: "向导设置字段"), range: 1...10_000_000, get: { appConfig.contextCompressionReminderTokenThreshold }, set: { appConfig.contextCompressionReminderTokenThreshold = $0 }),
            .bool("use_video_analysis_model", label: NSLocalizedString("非原生视频使用解析模型", comment: "向导设置字段"), get: { appConfig.enableVideoAnalysisForNonNativeModels }, set: { appConfig.enableVideoAnalysisForNonNativeModels = $0 }),
            .string("video_analysis_model", label: NSLocalizedString("视频解析模型", comment: "向导设置字段"), allowedValues: viewModel.videoAnalysisModelOptions.map(\.id), get: { appConfig.videoAnalysisModelIdentifier }, set: { setVideoAnalysisModelIdentifier($0) }),
            .string("video_frame_mode", label: NSLocalizedString("视频处理方式", comment: "向导设置字段"), allowedValues: VideoFrameExtractionMode.allCases.map(\.rawValue), get: { VideoFrameExtractionMode.normalized(appConfig.videoFrameExtractionMode).rawValue }, set: { appConfig.videoFrameExtractionMode = $0 }),
            .double("video_frame_fps", label: NSLocalizedString("视频抽帧速率", comment: "向导设置字段"), range: 0.1...5, get: { videoFrameExtractionFPSBinding.wrappedValue }, set: { videoFrameExtractionFPSBinding.wrappedValue = $0 }),
            .integer("video_frame_maximum_count", label: NSLocalizedString("最多画面数", comment: "向导设置字段"), range: 4...120, get: { videoFrameMaximumCountBinding.wrappedValue }, set: { videoFrameMaximumCountBinding.wrappedValue = $0 })
        ]
        if !viewModel.automaticHistoryLoadingEnabled {
            settings.append(.integer("initial_visible_messages", label: NSLocalizedString("初始显示消息数", comment: "向导设置字段"), range: 1...100_000, get: { lazyLoadMessageCount }, set: { lazyLoadMessageCount = $0 }))
        }
        return settings
    }

    private var promptGuideSettings: [GuidePageSetting] {
        var settings: [GuidePageSetting] = [
            .bool("model_picker_prompt_shortcut", label: NSLocalizedString("在模型选择器中显示提示词", comment: "向导设置字段"), get: { appConfig.modelPickerPromptShortcutEnabled }, set: { appConfig.modelPickerPromptShortcutEnabled = $0 }),
            .readOnly("global_prompt_count", label: NSLocalizedString("全局提示词数量", comment: "向导设置字段"), value: { .int(globalSystemPromptEntries.count) }),
            .readOnly("selected_global_prompt_id", label: NSLocalizedString("当前全局提示词 ID", comment: "向导设置字段"), value: { .string(selectedGlobalSystemPromptEntryID?.uuidString ?? "") }),
            .bool("enhanced_prompt_uses_system_role", label: NSLocalizedString("增强提示词使用 System 角色", comment: "向导设置字段"), get: { appConfig.openAITailContextUsesSystemRole }, set: { appConfig.openAITailContextUsesSystemRole = $0 }),
            .bool("include_system_time", label: NSLocalizedString("发送系统时间", comment: "向导设置字段"), get: { includeSystemTimeInPrompt }, set: { includeSystemTimeInPrompt = $0 }),
            .string("system_time_position", label: NSLocalizedString("系统时间发送位置", comment: "向导设置字段"), allowedValues: SystemTimeInjectionPosition.allCases.map(\.rawValue), get: { systemTimeInjectionPosition.rawValue }, set: { if let value = SystemTimeInjectionPosition(rawValue: $0) { systemTimeInjectionPosition = value } }),
            .bool("periodic_time_landmark", label: NSLocalizedString("周期性时间路标", comment: "向导设置字段"), get: { enablePeriodicTimeLandmark }, set: { enablePeriodicTimeLandmark = $0 }),
            .integer("time_landmark_interval_minutes", label: NSLocalizedString("路标间隔分钟", comment: "向导设置字段"), range: 1...525_600, get: { periodicTimeLandmarkIntervalMinutes }, set: { periodicTimeLandmarkIntervalMinutes = $0 })
        ]
        if selectedGlobalPromptEntry != nil {
            settings.append(.string("selected_global_prompt_content", label: NSLocalizedString("当前全局系统提示词", comment: "向导设置字段"), get: { selectedGlobalPromptEntry?.content ?? "" }, set: { updateSelectedGlobalSystemPromptContent($0) }))
        }
        if currentSession != nil {
            settings.append(.string("current_topic_prompt", label: NSLocalizedString("当前话题提示词", comment: "向导设置字段"), get: { currentSession?.topicPrompt ?? "" }, set: { setTopicPromptFromGuide($0) }))
            settings.append(.string("current_enhanced_prompt", label: NSLocalizedString("当前增强提示词", comment: "向导设置字段"), get: { currentSession?.enhancedPrompt ?? "" }, set: { setEnhancedPromptFromGuide($0) }))
        }
        return settings
    }

    private var outputGuideSettings: [GuidePageSetting] {
        [
            .bool("temperature_enabled", label: NSLocalizedString("自定义 Temperature", comment: "向导设置字段"), get: { aiTemperatureEnabled }, set: { aiTemperatureEnabled = $0 }),
            .double("temperature", label: NSLocalizedString("Temperature", comment: "向导设置字段"), range: temperatureRange, get: { temperatureBinding.wrappedValue }, set: { temperatureBinding.wrappedValue = $0 }),
            .bool("top_p_enabled", label: NSLocalizedString("自定义 Top P", comment: "向导设置字段"), get: { aiTopPEnabled }, set: { aiTopPEnabled = $0 }),
            .double("top_p", label: NSLocalizedString("Top P", comment: "向导设置字段"), range: topPRange, get: { topPBinding.wrappedValue }, set: { topPBinding.wrappedValue = $0 }),
            .bool("streaming_enabled", label: NSLocalizedString("启用流式输出", comment: "向导设置字段"), get: { enableStreaming }, set: { enableStreaming = $0 }),
            .bool("stream_include_usage", label: NSLocalizedString("流式附带官方 Token 用量", comment: "向导设置字段"), get: { enableOpenAIStreamIncludeUsage }, set: { enableOpenAIStreamIncludeUsage = $0 }),
            .bool("reasoning_summary", label: NSLocalizedString("启用思考摘要", comment: "向导设置字段"), get: { enableReasoningSummary }, set: { enableReasoningSummary = $0 }),
            .string("reasoning_content_echo_mode", label: NSLocalizedString("思维链回传", comment: "向导设置字段"), allowedValues: ReasoningContentEchoMode.allCases.map(\.rawValue), get: { ReasoningContentEchoMode.normalized(appConfig.reasoningContentEchoMode).rawValue }, set: { appConfig.reasoningContentEchoMode = $0 }),
            .bool("response_speed_metrics", label: NSLocalizedString("启用响应测速", comment: "向导设置字段"), get: { enableResponseSpeedMetrics }, set: { enableResponseSpeedMetrics = $0 })
        ]
    }

    private func setTopicPromptFromGuide(_ value: String) {
        guard var session = currentSession else { return }
        session.topicPrompt = value
        currentSession = session
        ChatService.shared.updateSession(session)
    }

    private func setEnhancedPromptFromGuide(_ value: String) {
        guard var session = currentSession else { return }
        session.enhancedPrompt = value
        currentSession = session
        ChatService.shared.updateSession(session)
    }

    private var conversationRuntimeBudgetBinding: Binding<Int> {
        Binding(
            get: { max(1, appConfig.conversationRuntimeExecutionBudget) },
            set: { appConfig.conversationRuntimeExecutionBudget = max(1, $0) }
        )
    }

    private func samplingParameterField(title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            // 数值输入避开 watchOS Slider/Stepper 在小屏上的异常布局。
            TextField("", value: value, formatter: samplingParameterFormatter)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 64)
                .accessibilityLabel(Text(title))
        }
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { normalizedSamplingValue(aiTemperature, in: temperatureRange) },
            set: { handleTemperatureChange($0) }
        )
    }

    private var temperatureSliderPosition: Double {
        let span = temperatureRange.upperBound - temperatureRange.lowerBound
        return (temperatureBinding.wrappedValue - temperatureRange.lowerBound) / span
    }

    private var temperatureDisplayValue: String {
        temperatureBinding.wrappedValue.formatted(.number.precision(.fractionLength(2)))
    }

    private var topPBinding: Binding<Double> {
        Binding(
            get: { normalizedSamplingValue(aiTopP, in: topPRange) },
            set: { handleTopPChange($0) }
        )
    }

    private var reasoningContentEchoModeBinding: Binding<ReasoningContentEchoMode> {
        Binding(
            get: { ReasoningContentEchoMode.normalized(appConfig.reasoningContentEchoMode) },
            set: { appConfig.reasoningContentEchoMode = $0.rawValue }
        )
    }

    private var sendDelayBinding: Binding<Double> {
        Binding(
            get: { normalizedSendDelay(appConfig.chatSendDelaySeconds) },
            set: { appConfig.chatSendDelaySeconds = normalizedSendDelay($0) }
        )
    }

    private var videoFrameExtractionModeBinding: Binding<VideoFrameExtractionMode> {
        Binding(
            get: { VideoFrameExtractionMode.normalized(appConfig.videoFrameExtractionMode) },
            set: { appConfig.videoFrameExtractionMode = $0.rawValue }
        )
    }

    private var videoFrameExtractionFPSBinding: Binding<Double> {
        Binding(
            get: { min(max(appConfig.videoFrameExtractionFPS, 0.1), 5) },
            set: { appConfig.videoFrameExtractionFPS = min(max($0, 0.1), 5) }
        )
    }

    private var videoFrameMaximumCountBinding: Binding<Int> {
        Binding(
            get: { min(max(appConfig.videoFrameMaximumCount, 4), 120) },
            set: { appConfig.videoFrameMaximumCount = min(max($0, 4), 120) }
        )
    }

    private var videoAnalysisModelIdentifierBinding: Binding<String> {
        Binding(
            get: { appConfig.videoAnalysisModelIdentifier },
            set: { setVideoAnalysisModelIdentifier($0) }
        )
    }

    private func syncVideoAnalysisModelSelection() {
        let options = viewModel.videoAnalysisModelOptions
        guard !options.isEmpty else {
            if !appConfig.videoAnalysisModelIdentifier.isEmpty {
                setVideoAnalysisModelIdentifier("")
            }
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

    private var settingsIntroSummary: String {
        switch destination {
        case .conversation:
            return [
                NSLocalizedString("启动与发送", comment: "Conversation launch and send settings section"),
                NSLocalizedString("上下文窗口管理", comment: ""),
                NSLocalizedString("消息规则", comment: ""),
                NSLocalizedString("视频发送", comment: "Video sending settings section")
            ].joined(separator: " · ")
        case .prompts:
            return [
                NSLocalizedString("全局系统提示词", comment: ""),
                NSLocalizedString("增强提示词", comment: ""),
                NSLocalizedString("内置提示词", comment: "Built-in prompt settings section"),
                NSLocalizedString("动态时间注入", comment: "")
            ].joined(separator: " · ")
        case .output:
            return [
                NSLocalizedString("采样参数", comment: ""),
                NSLocalizedString("流式输出", comment: ""),
                NSLocalizedString("思考与推理", comment: "Output reasoning settings section"),
                NSLocalizedString("语音朗读", comment: "TTS output settings section")
            ].joined(separator: " · ")
        }
    }

    private var settingsIntroDetails: String {
        switch destination {
        case .conversation:
            return introDetails([
                (
                    NSLocalizedString("启动与发送", comment: "Conversation launch and send settings section"),
                    [
                        NSLocalizedString("离开时间未超过该期限时恢复上次会话；超过后打开新对话。", comment: "Recent session restore behavior explanation"),
                        NSLocalizedString("设置为 0 时立即发送；大于 0 时，点击发送后会等待对应秒数，期间可点停止取消。", comment: "Send delay setting footer")
                    ].joined(separator: "\n\n")
                ),
                (
                    NSLocalizedString("上下文窗口管理", comment: ""),
                    [
                        NSLocalizedString("开启后会在接近边缘时自动加载并回收历史气泡。关闭后按设置显示最近消息，每次向上加载 5 条；回到底部时恢复初始范围。设为 0 时显示全部历史。", comment: "自动管理聊天历史窗口说明"),
                        NSLocalizedString("达到阈值后，系统会发送通知；点击通知会立即按默认参数创建续聊会话，原会话会完整保留。", comment: "Watch context compression reminder settings explanation")
                    ].joined(separator: "\n\n")
                ),
                (
                    NSLocalizedString("消息规则", comment: ""),
                    NSLocalizedString("规则会按列表顺序应用。保存替换会写入消息；仅发送只影响模型请求；仅显示只影响聊天气泡展示。", comment: "")
                ),
                (
                    NSLocalizedString("视频发送", comment: "Video sending settings section"),
                    NSLocalizedString("在 Gemini 模型的输入模态中启用“视频”后，手表会通过 Gemini Files API 发送原视频；关闭该模态或切换到其他模型时，会从保留的原视频生成带时间戳的画面。watchOS 的非原生视频抽帧由配对 iPhone 协助完成。", comment: "Watch video sending settings detailed explanation")
                )
            ])
        case .prompts:
            return introDetails([
                (
                    NSLocalizedString("提示词", comment: "Core prompt settings title"),
                    [
                        NSLocalizedString("在二级菜单中可右滑删除、左滑更多（编辑），点选条目会自动返回。", comment: ""),
                        NSLocalizedString("该提示词会附加在您的最后一条消息末尾，以增强指令效果。", comment: ""),
                        NSLocalizedString("警告：直接在前置系统提示词中插入 <time> 可能会降低上下文缓存命中率。若可行，优先使用末尾发送，或改用获取系统时间工具。", comment: "")
                    ].joined(separator: "\n\n")
                ),
                (
                    NSLocalizedString("内置提示词", comment: "Built-in prompt settings section"),
                    NSLocalizedString("未自定义时会跟随应用语言使用内置模板；自定义后会固定使用保存内容。", comment: "Built-in prompt settings footer")
                )
            ])
        case .output:
            return introDetails([
                (
                    NSLocalizedString("思考与推理", comment: "Output reasoning settings section"),
                    reasoningContentEchoDetails
                ),
                (
                    NSLocalizedString("响应测速与统计", comment: "Response speed metrics section title"),
                    NSLocalizedString("开启后会记录单次 API 请求的总回复时间；流式时还会记录首字时间和 token/s。", comment: "Response speed metrics description")
                )
            ])
        }
    }

    private var reasoningContentEchoFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("开启思考摘要后会在思考完成后异步生成一行摘要，并显示在思考耗时后面。", comment: ""))
            if reasoningContentEchoModeBinding.wrappedValue == .never {
                Text(NSLocalizedString("选择“不回传”后，某些要求回传 reasoning_content 或思考签名元数据的 API 可能会返回 400 错误。", comment: ""))
            }
        }
        .etFont(.footnote)
        .foregroundStyle(.secondary)
    }

    private var reasoningContentEchoDetails: String {
        let base = NSLocalizedString("开启思考摘要后会在思考完成后异步生成一行摘要，并显示在思考耗时后面。", comment: "")
        let compatibility = NSLocalizedString("该设置会控制 OpenAI 兼容请求中的 reasoning_content、Gemini 工具调用的 thoughtSignature，以及 Anthropic 工具调用历史中的 thinking/redacted_thinking 块回传。Gemini 与 Anthropic 官方要求工具调用延续时保留这些签名元数据；非工具调用的完整原始思考块当前无法可靠重建，因此不会额外伪造回传。", comment: "")
        if reasoningContentEchoModeBinding.wrappedValue == .never {
            let warning = NSLocalizedString("选择“不回传”后，某些要求回传 reasoning_content 或思考签名元数据的 API 可能会返回 400 错误。", comment: "")
            return "\(base)\n\n\(compatibility)\n\n\(warning)"
        }
        return "\(base)\n\n\(compatibility)"
    }

    private func introDetails(_ sections: [(String, String)]) -> String {
        sections
            .map { "\($0.0)\n\($0.1)" }
            .joined(separator: "\n\n")
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .etFont(.footnote.weight(.semibold))
            Text(summary)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: ""))
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(details)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private func handleTemperatureChange(_ value: Double) {
        let roundedValue = normalizedSamplingValue(value, in: temperatureRange)
        if aiTemperature != roundedValue {
            aiTemperature = roundedValue
        }
        unlockTemperatureBoundaryAchievementIfNeeded(roundedValue)
    }

    private func handleTopPChange(_ value: Double) {
        let roundedValue = normalizedSamplingValue(value, in: topPRange)
        if aiTopP != roundedValue {
            aiTopP = roundedValue
        }
    }

    private func normalizeSamplingParametersIfNeeded() {
        handleTemperatureChange(aiTemperature)
        handleTopPChange(aiTopP)
    }

    private func syncContextCompressionReminderThresholdDraft() {
        contextCompressionReminderThresholdDraft = String(
            appConfig.contextCompressionReminderTokenThreshold
        )
    }

    private func commitContextCompressionReminderThresholdDraft() {
        let resolvedThreshold = ContextCompressionReminderPolicy.resolvedTokenThreshold(
            from: contextCompressionReminderThresholdDraft,
            fallback: appConfig.contextCompressionReminderTokenThreshold
        )
        if appConfig.contextCompressionReminderTokenThreshold != resolvedThreshold {
            appConfig.contextCompressionReminderTokenThreshold = resolvedThreshold
        }
        contextCompressionReminderThresholdDraft = String(resolvedThreshold)
        isEditingContextCompressionReminderThreshold = false
    }

    private func normalizedSamplingValue(_ value: Double, in range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        let clampedValue = min(max(value, range.lowerBound), range.upperBound)
        return (clampedValue / samplingParameterStep).rounded() * samplingParameterStep
    }

    private func normalizedSendDelay(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    private func unlockTemperatureBoundaryAchievementIfNeeded(_ value: Double) {
        let achievementID: AchievementID?
        if value == 2.0 {
            achievementID = .wildTemperature
        } else if value == 0.0 {
            achievementID = .absoluteReason
        } else {
            achievementID = nil
        }

        guard let achievementID else { return }
        Task {
            let hasUnlocked = AchievementCenter.shared.hasUnlocked(id: achievementID)
            guard !hasUnlocked else { return }
            await AchievementCenter.shared.unlock(id: achievementID)
        }
    }

    private func displayTitle(for entry: GlobalSystemPromptEntry?) -> String {
        guard let entry else { return NSLocalizedString("未选择", comment: "") }
        let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? NSLocalizedString("未命名提示词", comment: "") : trimmedTitle
    }
}

private struct GlobalSystemPromptPickerView: View {
    let entries: [GlobalSystemPromptEntry]
    let selectedEntryID: UUID?
    let addGlobalSystemPromptEntry: () -> Void
    let selectGlobalSystemPromptEntry: (UUID?) -> Void
    let updateGlobalSystemPromptEntry: (UUID, String, String) -> Void
    let deleteGlobalSystemPromptEntry: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editingEntry: GlobalSystemPromptEntry?

    var body: some View {
        List {
            Section {
                Button {
                    addGlobalSystemPromptEntry()
                } label: {
                    Label(NSLocalizedString("新增提示词", comment: ""), systemImage: "plus")
                }
            }

            Section(NSLocalizedString("全局系统提示词", comment: "")) {
                ForEach(entries) { entry in
                    Button {
                        selectGlobalSystemPromptEntry(entry.id)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayTitle(for: entry))
                                    .lineLimit(1)
                                Text(displayPreview(for: entry))
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if selectedEntryID == entry.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteGlobalSystemPromptEntry(entry.id)
                        } label: {
                            Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            editingEntry = entry
                        } label: {
                            Label(NSLocalizedString("更多", comment: ""), systemImage: "ellipsis.circle")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("全局提示词", comment: ""))
        .guideSettingsPageContext(
            id: "settings-global-system-prompts",
            title: NSLocalizedString("全局提示词", comment: "全局提示词列表向导上下文标题"),
            documents: [GuideDocumentReference(id: "settings-core", title: "Core Settings")],
            settings: guideSettings
        )
        .watchGuideEntry()
        .sheet(item: $editingEntry) { entry in
            GlobalSystemPromptEditorView(entry: entry) { title, content in
                updateGlobalSystemPromptEntry(entry.id, title, content)
            }
        }
    }

    private var guideSettings: [GuidePageSetting] {
        var settings: [GuidePageSetting] = [
            .readOnly(
                "entries",
                label: NSLocalizedString("全局系统提示词列表", comment: "全局提示词向导字段"),
                value: {
                    .array(entries.map { entry in
                        .dictionary([
                            "id": .string(entry.id.uuidString),
                            "title": .string(entry.title),
                            "content": .string(entry.content)
                        ])
                    })
                }
            )
        ]
        let entryIDs = entries.map { $0.id.uuidString }
        if !entryIDs.isEmpty {
            settings.append(
                .string(
                    "selected_entry_id",
                    label: NSLocalizedString("当前提示词", comment: "全局提示词向导字段"),
                    allowedValues: entryIDs,
                    allowsEmpty: false,
                    get: { selectedEntryID?.uuidString ?? entryIDs[0] },
                    set: { value in
                        guard let id = UUID(uuidString: value) else { return }
                        selectGlobalSystemPromptEntry(id)
                    }
                )
            )
        }
        return settings
    }

    private func displayTitle(for entry: GlobalSystemPromptEntry) -> String {
        let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? NSLocalizedString("未命名提示词", comment: "") : trimmedTitle
    }

    private func displayPreview(for entry: GlobalSystemPromptEntry) -> String {
        let trimmedContent = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContent.isEmpty {
            return NSLocalizedString("空提示词（不发送）", comment: "")
        }
        return trimmedContent.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

private struct GlobalSystemPromptEditorView: View {
    let entry: GlobalSystemPromptEntry
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var content: String

    init(entry: GlobalSystemPromptEntry, onSave: @escaping (String, String) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _title = State(initialValue: entry.title)
        _content = State(initialValue: entry.content)
    }

    var body: some View {
        NavigationStack {
            List {
                TextField(NSLocalizedString("提示词名称", comment: ""), text: $title.watchKeyboardNewlineBinding())
                TextField(NSLocalizedString("提示词内容", comment: ""), text: $content.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(4...10)

                Button(NSLocalizedString("保存修改", comment: "")) {
                    onSave(title, content)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle(NSLocalizedString("编辑提示词", comment: ""))
        }
        .guideSettingsPageContext(
            id: "settings-global-system-prompt-editor",
            title: NSLocalizedString("编辑提示词", comment: "全局提示词编辑向导上下文标题"),
            documents: [GuideDocumentReference(id: "settings-core", title: "Core Settings")],
            settings: [
                .string("title", label: NSLocalizedString("提示词名称", comment: "全局提示词向导字段"), get: { title }, set: { title = $0 }),
                .string("content", label: NSLocalizedString("提示词内容", comment: "全局提示词向导字段"), get: { content }, set: { content = $0 }),
                .readOnly(
                    "save_required",
                    label: NSLocalizedString("修改后需要保存", comment: "向导保存说明"),
                    value: { .bool(true) }
                )
            ]
        )
        .watchGuideEntry()
    }
}
