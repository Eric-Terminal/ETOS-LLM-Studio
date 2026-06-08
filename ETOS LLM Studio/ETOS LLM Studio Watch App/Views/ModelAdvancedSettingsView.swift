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

/// 偏好设置视图
struct ModelAdvancedSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared

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
            // MARK: Section 1：提示与注入
            Section(
                header: Text(NSLocalizedString("全局系统提示词", comment: "")),
                footer: Text(NSLocalizedString("在二级菜单中可右滑删除、左滑更多（编辑），点选条目会自动返回。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
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

            Section(header: Text(NSLocalizedString("增强提示词", comment: "")), footer: Text(NSLocalizedString("该提示词会附加在您的最后一条消息末尾，以增强指令效果。", comment: ""))) {
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
            }

            Section(
                header: Text(NSLocalizedString("系统时间注入", comment: "")),
                footer: Text(NSLocalizedString("警告：直接在前置系统提示词中插入 <time> 可能会降低上下文缓存命中率。若可行，优先使用末尾发送，或改用获取系统时间工具。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(NSLocalizedString("发送系统时间", comment: ""), isOn: $includeSystemTimeInPrompt)
                if includeSystemTimeInPrompt {
                    Picker(NSLocalizedString("发送位置", comment: ""), selection: $systemTimeInjectionPosition) {
                        ForEach(SystemTimeInjectionPosition.allCases) { position in
                            Text(position.displayName).tag(position)
                        }
                    }
                }
            }

            Section(header: Text(NSLocalizedString("提示与注入", comment: ""))) {
                Toggle(NSLocalizedString("周期性时间路标", comment: ""), isOn: $enablePeriodicTimeLandmark)
            }

            // MARK: Section 2：消息规则
            Section(
                header: Text(NSLocalizedString("消息规则", comment: "")),
                footer: Text(NSLocalizedString("规则会按列表顺序应用。保存替换会写入消息；仅发送只影响模型请求；仅显示只影响聊天气泡展示。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                NavigationLink {
                    MessageRegexRulesView()
                } label: {
                    Label(NSLocalizedString("正则替换", comment: ""), systemImage: "textformat")
                }
            }

            // MARK: Section 3：会话与上下文
            Section(header: Text(NSLocalizedString("会话与上下文", comment: ""))) {
                Toggle(NSLocalizedString("启动时打开历史会话", comment: ""), isOn: $appConfig.restoreLastSessionOnLaunch)
                Toggle(NSLocalizedString("自动生成话题标题", comment: ""), isOn: $enableAutoSessionNaming)

                HStack {
                    Text(NSLocalizedString("最大上下文消息数", comment: ""))
                    Spacer()
                    TextField(NSLocalizedString("数量", comment: ""), value: $maxChatHistory, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }

                HStack {
                    Text(NSLocalizedString("懒加载轮次", comment: ""))
                    Spacer()
                    TextField(NSLocalizedString("数量", comment: ""), value: $lazyLoadMessageCount, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
            }

            // MARK: Section 4：生成与输出
            Section(
                header: Text(NSLocalizedString("生成与输出", comment: "")),
                footer: reasoningContentEchoFooter
            ) {
                Toggle(NSLocalizedString("流式输出", comment: ""), isOn: $enableStreaming)
                Toggle(NSLocalizedString("启用思考摘要", comment: ""), isOn: $enableReasoningSummary)
                Picker(NSLocalizedString("思维链回传", comment: ""), selection: reasoningContentEchoModeBinding) {
                    ForEach(ReasoningContentEchoMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Toggle(NSLocalizedString("启用响应测速", comment: "Enable response speed metrics"), isOn: $enableResponseSpeedMetrics)

                Toggle(NSLocalizedString("自定义 Temperature", comment: ""), isOn: $aiTemperatureEnabled)
                if aiTemperatureEnabled {
                    samplingParameterField(
                        title: NSLocalizedString("温度", comment: "Temperature sampling parameter title"),
                        value: temperatureBinding
                    )
                }

                Toggle(NSLocalizedString("自定义 Top P", comment: ""), isOn: $aiTopPEnabled)
                if aiTopPEnabled {
                    samplingParameterField(
                        title: NSLocalizedString("Top-P", comment: "Top P sampling parameter title"),
                        value: topPBinding
                    )
                }
            }

            Section {
                NavigationLink(destination: WatchKeyboardSettingsView()) {
                    Label(NSLocalizedString("键盘", comment: "Keyboard settings title"), systemImage: "keyboard")
                }
            }
        }
        .navigationTitle(NSLocalizedString("偏好设置", comment: ""))
        .onAppear {
            normalizeSamplingParametersIfNeeded()
        }
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

    private var reasoningContentEchoFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("开启思考摘要后会在思考完成后异步生成一行摘要，并显示在思考耗时后面。", comment: ""))
            Text(NSLocalizedString("该设置会控制 OpenAI 兼容请求中的 reasoning_content、Gemini 工具调用的 thoughtSignature，以及 Anthropic 工具调用历史中的 thinking/redacted_thinking 块回传。Gemini 与 Anthropic 官方要求工具调用延续时保留这些签名元数据；非工具调用的完整原始思考块当前无法可靠重建，因此不会额外伪造回传。", comment: ""))
            if reasoningContentEchoModeBinding.wrappedValue == .never {
                Text(NSLocalizedString("选择“不回传”后，某些要求回传 reasoning_content 或思考签名元数据的 API 可能会返回 400 错误。", comment: ""))
            }
        }
        .etFont(.footnote)
        .foregroundStyle(.secondary)
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
    }
}
