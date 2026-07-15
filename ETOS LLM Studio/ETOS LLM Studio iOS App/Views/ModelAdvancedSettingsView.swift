// ============================================================================
// ModelAdvancedSettingsView.swift
// ============================================================================
// ModelAdvancedSettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import ETOSCore

private enum ModelAdvancedSettingsTab: Hashable {
    case promptInjection
    case builtInPrompts
    case messageRules
    case sessionContext
    case generationOutput
}

private enum ModelAdvancedSettingsFocusedField: Hashable {
    case contextCompressionReminderThreshold
}

struct ModelAdvancedSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var selectedTab: ModelAdvancedSettingsTab = .promptInjection
    @State private var editingMessageRegexRule: MessageRegexRule?
    @State private var selectedGlobalPromptDraft: String = ""
    @State private var topicPromptDraft: String = ""
    @State private var enhancedPromptDraft: String = ""
    @State private var contextCompressionReminderThresholdDraft: String = ""
    @State private var isShowingPromptInjectionIntro = false
    @State private var isShowingSessionContextIntro = false
    @State private var isShowingGenerationOutputIntro = false
    @FocusState private var focusedField: ModelAdvancedSettingsFocusedField?

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

    private let samplingParameterStep = 0.01
    private let temperatureRange = 0.0...2.0
    private let topPRange = 0.0...1.0

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
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
            get: { selectedGlobalPromptDraft },
            set: { selectedGlobalPromptDraft = $0 }
        )
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // MARK: - Tab 1：提示与注入
            Form {
                Section {
                    settingsIntroCard(
                        title: NSLocalizedString("提示与注入", comment: ""),
                        summary: promptInjectionIntroSummary,
                        details: promptInjectionIntroDetails,
                        isExpanded: $isShowingPromptInjectionIntro
                    )
                }

                Section {
                    FullscreenMultilineTextInput(
                        identity: selectedGlobalPromptEntry?.id.uuidString ?? "global-system-prompt-none",
                        placeholder: NSLocalizedString("自定义全局系统提示词", comment: ""),
                        fullScreenTitle: NSLocalizedString("编辑提示词", comment: ""),
                        text: selectedGlobalPromptContentBinding,
                        lineLimit: 3...8,
                        isEnabled: selectedGlobalPromptEntry != nil,
                        onDebouncedSave: { newValue in
                            updateSelectedGlobalSystemPromptContent(newValue)
                        }
                    )

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
                        LabeledContent(NSLocalizedString("提示词列表", comment: "")) {
                            Text(displayTitle(for: selectedGlobalPromptEntry))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("全局系统提示词", comment: ""))
                }

                Section {
                    FullscreenMultilineTextInput(
                        identity: currentSession?.id.uuidString ?? "topic-prompt-none",
                        placeholder: NSLocalizedString("自定义话题提示词", comment: ""),
                        fullScreenTitle: NSLocalizedString("编辑提示词", comment: ""),
                        text: Binding(
                            get: { topicPromptDraft },
                            set: { topicPromptDraft = $0 }
                        ),
                        lineLimit: 2...6,
                        isEnabled: currentSession != nil,
                        onDebouncedSave: { newValue in
                            guard var session = currentSession else { return }
                            session.topicPrompt = newValue
                            currentSession = session
                            ChatService.shared.updateSession(session)
                        }
                    )
                } header: {
                    Text(NSLocalizedString("当前话题提示词", comment: ""))
                } footer: {
                    Text(NSLocalizedString("仅对当前对话生效。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    FullscreenMultilineTextInput(
                        identity: currentSession?.id.uuidString ?? "enhanced-prompt-none",
                        placeholder: NSLocalizedString("自定义增强提示词", comment: ""),
                        fullScreenTitle: NSLocalizedString("编辑提示词", comment: ""),
                        text: Binding(
                            get: { enhancedPromptDraft },
                            set: { enhancedPromptDraft = $0 }
                        ),
                        lineLimit: 2...6,
                        isEnabled: currentSession != nil,
                        onDebouncedSave: { newValue in
                            guard var session = currentSession else { return }
                            session.enhancedPrompt = newValue
                            currentSession = session
                            ChatService.shared.updateSession(session)
                        }
                    )
                } header: {
                    Text(NSLocalizedString("增强提示词", comment: ""))
                } footer: {
                    Text(NSLocalizedString("该提示词会附加在您的最后一条消息末尾，以增强指令效果。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(NSLocalizedString("发送系统时间", comment: ""), isOn: $includeSystemTimeInPrompt)
                    if includeSystemTimeInPrompt {
                        Picker(NSLocalizedString("发送位置", comment: ""), selection: $systemTimeInjectionPosition) {
                            ForEach(SystemTimeInjectionPosition.allCases) { position in
                                Text(position.displayName).tag(position)
                            }
                        }
                    }
                    Toggle(NSLocalizedString("周期性时间路标", comment: ""), isOn: $enablePeriodicTimeLandmark)
                    LabeledContent(NSLocalizedString("路标时间（分钟）", comment: "")) {
                        TextField(NSLocalizedString("分钟", comment: ""), value: $periodicTimeLandmarkIntervalMinutes, formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .disabled(!enablePeriodicTimeLandmark)
                    }
                } header: {
                    Text(NSLocalizedString("动态时间注入", comment: ""))
                }
                .onChange(of: periodicTimeLandmarkIntervalMinutes) { _, newValue in
                    if newValue < 1 {
                        periodicTimeLandmarkIntervalMinutes = 1
                    }
                }
            }
            .tabItem {
                Label(NSLocalizedString("提示与注入", comment: ""), systemImage: "text.quote")
            }
            .tag(ModelAdvancedSettingsTab.promptInjection)

            // MARK: - Tab 2：内置提示词
            BuiltInPromptSettingsView(usesCategoryTabs: false)
                .tabItem {
                    Label(NSLocalizedString("内置提示词", comment: "Built-in prompt settings tab"), systemImage: "curlybraces")
                }
                .tag(ModelAdvancedSettingsTab.builtInPrompts)

            // MARK: - Tab 3：消息规则
            MessageRegexRulesView(editingRule: $editingMessageRegexRule)
                .tabItem {
                    Label(NSLocalizedString("消息规则", comment: ""), systemImage: "textformat")
                }
                .tag(ModelAdvancedSettingsTab.messageRules)

            // MARK: - Tab 4：会话与上下文
            Form {
                Section {
                    settingsIntroCard(
                        title: NSLocalizedString("会话与上下文", comment: ""),
                        summary: sessionContextIntroSummary,
                        details: sessionContextIntroDetails,
                        isExpanded: $isShowingSessionContextIntro
                    )
                }

                Section {
                    Toggle(NSLocalizedString("启动时打开历史会话", comment: ""), isOn: $appConfig.restoreLastSessionOnLaunch)
                    Toggle(NSLocalizedString("自动生成话题标题", comment: ""), isOn: $enableAutoSessionNaming)
                    LabeledContent(NSLocalizedString("延迟发送（秒）", comment: "Send delay seconds setting title")) {
                        TextField(NSLocalizedString("秒", comment: "Seconds placeholder"), value: sendDelayBinding, formatter: sendDelayFormatter)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 80)
                    }
                } header: {
                    Text(NSLocalizedString("基础行为", comment: ""))
                }

                Section(NSLocalizedString("上下文窗口管理", comment: "")) {
                    LabeledContent(NSLocalizedString("最大上下文消息数", comment: "")) {
                        TextField(NSLocalizedString("数量", comment: ""), value: $maxChatHistory, formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    LabeledContent(NSLocalizedString("懒加载轮次", comment: "")) {
                        TextField(NSLocalizedString("数量", comment: ""), value: $lazyLoadMessageCount, formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    Toggle(
                        NSLocalizedString("上下文压缩提醒", comment: "Context compression reminder toggle"),
                        isOn: $appConfig.enableContextCompressionReminder
                    )

                    if appConfig.enableContextCompressionReminder {
                        LabeledContent(NSLocalizedString(
                            "提醒阈值（Token）",
                            comment: "Context compression reminder token threshold"
                        )) {
                            TextField(
                                NSLocalizedString("Token", comment: "Token threshold field placeholder"),
                                text: $contextCompressionReminderThresholdDraft
                            )
                            .keyboardType(.numberPad)
                            .submitLabel(.done)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 100)
                            .focused(
                                $focusedField,
                                equals: .contextCompressionReminderThreshold
                            )
                            .onSubmit {
                                commitContextCompressionReminderThresholdDraft()
                                focusedField = nil
                            }
                        }
                    }

                }
            }
            .tabItem {
                Label(NSLocalizedString("会话与上下文", comment: ""), systemImage: "bubble.left.and.bubble.right")
            }
            .tag(ModelAdvancedSettingsTab.sessionContext)

            // MARK: - Tab 5：生成与输出
            Form {
                Section {
                    settingsIntroCard(
                        title: NSLocalizedString("生成与输出", comment: ""),
                        summary: generationOutputIntroSummary,
                        details: generationOutputIntroDetails,
                        isExpanded: $isShowingGenerationOutputIntro
                    )
                }

                Section(NSLocalizedString("采样参数", comment: "")) {
                    Toggle(NSLocalizedString("自定义 Temperature", comment: ""), isOn: $aiTemperatureEnabled)
                    if aiTemperatureEnabled {
                        Stepper(value: temperatureBinding, in: temperatureRange, step: samplingParameterStep) {
                            RequestBodySliderAnimatedValue(
                                text: temperatureDisplayText,
                                position: temperatureSliderPositionBinding.wrappedValue,
                                isNumeric: true
                            )
                            .monospacedDigit()
                        }

                        RequestBodyGradientSlider(
                            value: temperatureSliderPositionBinding,
                            palette: .temperature,
                            anchorCount: 3,
                            adjustmentStep: samplingParameterStep / (temperatureRange.upperBound - temperatureRange.lowerBound),
                            accessibilityLabel: NSLocalizedString("温度", comment: "Temperature sampling parameter title"),
                            accessibilityValue: temperatureDisplayText,
                            showsFlowingRainbow: false,
                            onEditingChanged: { _ in }
                        )
                        .sensoryFeedback(.selection, trigger: temperatureFeedbackAnchor)
                    }

                    Toggle(NSLocalizedString("自定义 Top P", comment: ""), isOn: $aiTopPEnabled)
                    if aiTopPEnabled {
                        Stepper(value: topPBinding, in: topPRange, step: samplingParameterStep) {
                            Text(
                                String(
                                    format: NSLocalizedString("核采样 (Top P): %.2f", comment: ""),
                                    topPBinding.wrappedValue
                                )
                            )
                        }

                        Slider(value: topPBinding, in: topPRange, step: samplingParameterStep)
                    }
                }

                Section {
                    Toggle(NSLocalizedString("启用流式输出", comment: ""), isOn: $enableStreaming)
                    Toggle(NSLocalizedString("启用思考摘要", comment: ""), isOn: $enableReasoningSummary)
                    Picker(NSLocalizedString("思维链回传", comment: ""), selection: reasoningContentEchoModeBinding) {
                        ForEach(ReasoningContentEchoMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("输出与思考", comment: ""))
                } footer: {
                    Text(compactOutputReasoningFooterText)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(NSLocalizedString("启用响应测速", comment: "Enable response speed metrics"), isOn: $enableResponseSpeedMetrics)
                    Toggle(NSLocalizedString("流式附带官方 Token 用量", comment: "Enable stream include usage in OpenAI-compatible requests"), isOn: $enableOpenAIStreamIncludeUsage)
                } header: {
                    Text(NSLocalizedString("响应测速与统计", comment: "Response speed metrics section title"))
                }

            }
            .tabItem {
                Label(NSLocalizedString("生成与输出", comment: ""), systemImage: "waveform")
            }
            .tag(ModelAdvancedSettingsTab.generationOutput)
        }
        .navigationTitle(NSLocalizedString("偏好设置", comment: ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if selectedTab == .messageRules {
                    Button {
                        editingMessageRegexRule = MessageRegexRule()
                    } label: {
                        Label(NSLocalizedString("新增规则", comment: ""), systemImage: "plus")
                    }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                if focusedField == .contextCompressionReminderThreshold {
                    Spacer()
                    Button(NSLocalizedString("完成", comment: "Finish numeric input action")) {
                        commitContextCompressionReminderThresholdDraft()
                        focusedField = nil
                    }
                }
            }
        }
        .onAppear {
            syncPromptDrafts()
            syncContextCompressionReminderThresholdDraft()
            normalizeSamplingParametersIfNeeded()
        }
        .onChange(of: focusedField) { oldValue, newValue in
            if oldValue == .contextCompressionReminderThreshold,
               newValue != .contextCompressionReminderThreshold {
                commitContextCompressionReminderThresholdDraft()
            }
        }
        .onChange(of: appConfig.contextCompressionReminderTokenThreshold) { _, _ in
            if focusedField != .contextCompressionReminderThreshold {
                syncContextCompressionReminderThresholdDraft()
            }
        }
        .onChange(of: appConfig.enableContextCompressionReminder) { _, isEnabled in
            if !isEnabled {
                commitContextCompressionReminderThresholdDraft()
                focusedField = nil
            }
        }
        .onChange(of: selectedGlobalSystemPromptEntryID) { _, _ in
            syncSelectedGlobalPromptDraft()
        }
        .onChange(of: selectedGlobalPromptEntry?.content ?? "") { _, _ in
            syncSelectedGlobalPromptDraft()
        }
        .onChange(of: currentSession?.id) { _, _ in
            syncSessionPromptDrafts()
        }
        .onChange(of: currentSession?.topicPrompt ?? "") { _, newValue in
            if topicPromptDraft != newValue {
                topicPromptDraft = newValue
            }
        }
        .onChange(of: currentSession?.enhancedPrompt ?? "") { _, newValue in
            if enhancedPromptDraft != newValue {
                enhancedPromptDraft = newValue
            }
        }
        .onDisappear {
            commitContextCompressionReminderThresholdDraft()
            persistPromptDrafts()
        }
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { normalizedSamplingValue(aiTemperature, in: temperatureRange) },
            set: { handleTemperatureChange($0) }
        )
    }

    private var temperatureSliderPositionBinding: Binding<Double> {
        let span = temperatureRange.upperBound - temperatureRange.lowerBound
        return Binding(
            get: {
                (temperatureBinding.wrappedValue - temperatureRange.lowerBound) / span
            },
            set: { position in
                temperatureBinding.wrappedValue = temperatureRange.lowerBound
                    + min(max(position, 0), 1) * span
            }
        )
    }

    private var temperatureDisplayText: String {
        String(
            format: NSLocalizedString("模型温度 (Temperature): %.2f", comment: ""),
            temperatureBinding.wrappedValue
        )
    }

    private var temperatureFeedbackAnchor: Int {
        Int(temperatureSliderPositionBinding.wrappedValue * 2 + 0.000_001)
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

    private var promptInjectionIntroSummary: String {
        [
            NSLocalizedString("全局系统提示词", comment: ""),
            NSLocalizedString("增强提示词", comment: ""),
            NSLocalizedString("动态时间注入", comment: "")
        ].joined(separator: " · ")
    }

    private var promptInjectionIntroDetails: String {
        introDetails([
            (
                NSLocalizedString("全局系统提示词", comment: ""),
                NSLocalizedString("为空时不会发送全局系统提示词。选择器中可右滑删除、左滑更多（编辑），点选条目会自动返回。", comment: "")
            ),
            (
                NSLocalizedString("当前话题提示词", comment: ""),
                NSLocalizedString("仅对当前对话生效。", comment: "")
            ),
            (
                NSLocalizedString("增强提示词", comment: ""),
                NSLocalizedString("该提示词会附加在您的最后一条消息末尾，以增强指令效果。", comment: "")
            ),
            (
                NSLocalizedString("动态时间注入", comment: ""),
                NSLocalizedString("警告：直接在前置系统提示词中插入 <time> 可能会降低上下文缓存命中率。若可行，优先使用末尾发送，或改用获取系统时间工具。\n\n开启路标后会按时间窗口在历史消息中自动插入一条 system 路标，提示对应位置的请求时间。", comment: "")
            )
        ])
    }

    private var sessionContextIntroSummary: String {
        [
            NSLocalizedString("基础行为", comment: ""),
            NSLocalizedString("上下文窗口管理", comment: ""),
            NSLocalizedString("上下文压缩提醒", comment: "Context compression reminder toggle")
        ].joined(separator: " · ")
    }

    private var sessionContextIntroDetails: String {
        introDetails([
            (
                NSLocalizedString("延迟发送（秒）", comment: "Send delay seconds setting title"),
                NSLocalizedString("设置为 0 时立即发送；大于 0 时，点击发送后会等待对应秒数，期间可点停止取消。", comment: "Send delay setting footer")
            ),
            (
                NSLocalizedString("懒加载轮次", comment: ""),
                NSLocalizedString("设置进入历史会话时默认加载的最近对话轮次（从最近一条用户消息开始向后）。数值越小，长对话加载越快；设置为 0 表示加载全部历史。", comment: "")
            ),
            (
                NSLocalizedString("上下文压缩提醒", comment: "Context compression reminder toggle"),
                NSLocalizedString("达到估算阈值后，系统会发送通知；点击通知会立即按默认参数创建续聊会话，原会话保持不变。Token 数为近似值，不会为了提醒读取附件或调用模型。", comment: "Context compression reminder settings explanation")
            )
        ])
    }

    private var generationOutputIntroSummary: String {
        [
            NSLocalizedString("采样参数", comment: ""),
            NSLocalizedString("输出与思考", comment: ""),
            NSLocalizedString("响应测速与统计", comment: "Response speed metrics section title")
        ].joined(separator: " · ")
    }

    private var generationOutputIntroDetails: String {
        introDetails([
            (
                NSLocalizedString("输出与思考", comment: ""),
                outputReasoningDetailsText
            ),
            (
                NSLocalizedString("响应测速与统计", comment: "Response speed metrics section title"),
                "\(NSLocalizedString("开启后会记录单次 API 请求的总回复时间；流式时还会记录首字时间和 token/s。", comment: "Response speed metrics description"))\n\n\(NSLocalizedString("“流式附带官方 Token 用量”会在 OpenAI 兼容流式请求中发送 stream_options.include_usage=true，部分平台若不兼容可关闭。", comment: "OpenAI stream include usage description"))"
            )
        ])
    }

    private var compactOutputReasoningFooterText: String {
        let base = NSLocalizedString("开启思考摘要后会在思考完成后异步生成一行摘要，并显示在思考耗时后面。", comment: "")
        if reasoningContentEchoModeBinding.wrappedValue == .never {
            return "\(base)\n\n\(NSLocalizedString("选择“不回传”后，某些要求回传 reasoning_content 或思考签名元数据的 API 可能会返回 400 错误。", comment: ""))"
        }
        return base
    }

    private var outputReasoningDetailsText: String {
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
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .etFont(.headline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(summary)
                .etFont(.subheadline)
                .foregroundStyle(.primary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: ""))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(details)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
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

    private func syncPromptDrafts() {
        syncSelectedGlobalPromptDraft()
        syncSessionPromptDrafts()
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
    }

    private func syncSelectedGlobalPromptDraft() {
        selectedGlobalPromptDraft = selectedGlobalPromptEntry?.content ?? ""
    }

    private func syncSessionPromptDrafts() {
        topicPromptDraft = currentSession?.topicPrompt ?? ""
        enhancedPromptDraft = currentSession?.enhancedPrompt ?? ""
    }

    private func persistPromptDrafts() {
        if selectedGlobalSystemPromptEntryID != nil {
            updateSelectedGlobalSystemPromptContent(selectedGlobalPromptDraft)
        }
        if var session = currentSession {
            session.topicPrompt = topicPromptDraft
            session.enhancedPrompt = enhancedPromptDraft
            currentSession = session
            ChatService.shared.updateSession(session)
        }
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
                            VStack(alignment: .leading, spacing: 4) {
                                Text(displayTitle(for: entry))
                                    .lineLimit(1)
                                Text(displayPreview(for: entry))
                                    .etFont(.footnote)
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
                    .buttonStyle(.plain)
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
                    .contextMenu {
                        Button {
                            editingEntry = entry
                        } label: {
                            Label(NSLocalizedString("编辑", comment: ""), systemImage: "square.and.pencil")
                        }
                        Button(role: .destructive) {
                            deleteGlobalSystemPromptEntry(entry.id)
                        } label: {
                            Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("全局提示词", comment: ""))
        .sheet(item: $editingEntry) { entry in
            GlobalSystemPromptEditorView(entry: entry) { title, content in
                updateGlobalSystemPromptEntry(entry.id, title, content)
            }
        }
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
    @State private var contentDraft: String

    init(entry: GlobalSystemPromptEntry, onSave: @escaping (String, String) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _title = State(initialValue: entry.title)
        _contentDraft = State(initialValue: entry.content)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(NSLocalizedString("提示词名称", comment: ""), text: $title)
                FullscreenMultilineTextInput(
                    identity: entry.id.uuidString,
                    placeholder: NSLocalizedString("提示词内容", comment: ""),
                    fullScreenTitle: NSLocalizedString("编辑提示词", comment: ""),
                    text: Binding(
                        get: { contentDraft },
                        set: { contentDraft = $0 }
                    ),
                    lineLimit: 4...10,
                    isEnabled: true,
                    onDebouncedSave: { newValue in
                        onSave(title, newValue)
                    }
                )
            }
            .navigationTitle(NSLocalizedString("编辑提示词", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) {
                        onSave(title, contentDraft)
                        dismiss()
                    }
                }
            }
        }
    }
}
