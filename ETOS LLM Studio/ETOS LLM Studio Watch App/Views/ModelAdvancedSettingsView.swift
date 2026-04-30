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
import Shared

/// 偏好设置视图
struct ModelAdvancedSettingsView: View {
    @AppStorage(ChatService.restoreLastSessionOnLaunchEnabledStorageKey) private var restoreLastSessionOnLaunch: Bool = false

    // MARK: - 绑定

    @Binding var aiTemperature: Double
    @Binding var aiTopP: Double
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

    // MARK: - 私有属性

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
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
        Form {
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

                Text(NSLocalizedString("在二级菜单中可右滑删除、左滑更多（编辑），点选条目会自动返回。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
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
                .lineLimit(5...10)
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
                .lineLimit(5...10)
            }

            Section(
                header: Text(NSLocalizedString("系统时间注入", comment: "")),
                footer: Text(NSLocalizedString("开启后可选择在前置系统提示词中插入 <time>，或在消息末尾追加一条 system 时间提示。", comment: ""))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
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

            Section(
                footer: Text(NSLocalizedString("开启后会按时间窗口在历史消息中自动插入一条 system 路标，提示对应位置的请求时间。", comment: ""))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            ) {
                Toggle(NSLocalizedString("周期性时间路标", comment: ""), isOn: $enablePeriodicTimeLandmark)
                HStack {
                    Text(NSLocalizedString("路标时间（分钟）", comment: ""))
                    Spacer()
                    TextField(NSLocalizedString("分钟", comment: ""), value: $periodicTimeLandmarkIntervalMinutes, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .disabled(!enablePeriodicTimeLandmark)
                }
            }
            .onChange(of: periodicTimeLandmarkIntervalMinutes) { _, newValue in
                if newValue < 1 {
                    periodicTimeLandmarkIntervalMinutes = 1
                }
            }

            Section(header: Text(NSLocalizedString("会话设置", comment: ""))) {
                Toggle(NSLocalizedString("启动时打开历史会话", comment: ""), isOn: $restoreLastSessionOnLaunch)
                Toggle(NSLocalizedString("自动生成话题标题", comment: ""), isOn: $enableAutoSessionNaming)
            }

            Section(
                header: Text(NSLocalizedString("思考内容", comment: "")),
                footer: Text(NSLocalizedString("开启后会在思考完成后异步生成一行摘要，并显示在思考耗时后面。", comment: ""))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            ) {
                Toggle(NSLocalizedString("启用思考摘要", comment: ""), isOn: $enableReasoningSummary)
            }

            Section(header: Text(NSLocalizedString("输出设置", comment: ""))) {
                Toggle(NSLocalizedString("流式输出", comment: ""), isOn: $enableStreaming)
            }

            Section(
                header: Text(NSLocalizedString("响应测速", comment: "Response speed metrics section title")),
                footer: Text(
                    "\(NSLocalizedString("开启后会记录单次 API 请求的总回复时间；流式时还会记录首字时间和 token/s。", comment: "Response speed metrics description"))\n\n\(NSLocalizedString("“流式附带官方 Token 用量”会在 OpenAI 兼容流式请求中发送 stream_options.include_usage=true，部分平台若不兼容可关闭。", comment: "OpenAI stream include usage description"))"
                )
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            ) {
                Toggle(NSLocalizedString("启用响应测速", comment: "Enable response speed metrics"), isOn: $enableResponseSpeedMetrics)
                Toggle(NSLocalizedString("流式附带官方 Token 用量", comment: "Enable stream include usage in OpenAI-compatible requests"), isOn: $enableOpenAIStreamIncludeUsage)
            }

            Section(header: Text(NSLocalizedString("参数调整", comment: ""))) {
                VStack(alignment: .leading) {
                    Text(
                        String(
                            format: NSLocalizedString("模型温度 (Temperature): %.2f", comment: ""),
                            aiTemperature
                        )
                    )
                    Slider(value: $aiTemperature, in: 0.0...2.0, step: 0.05)
                        .onChange(of: aiTemperature) {
                            handleTemperatureChange(aiTemperature)
                        }
                }

                VStack(alignment: .leading) {
                    Text(
                        String(
                            format: NSLocalizedString("核采样 (Top P): %.2f", comment: ""),
                            aiTopP
                        )
                    )
                    Slider(value: $aiTopP, in: 0.0...1.0, step: 0.05)
                        .onChange(of: aiTopP) {
                            aiTopP = (aiTopP * 100).rounded() / 100
                        }
                }
            }

            Section(
                header: Text(NSLocalizedString("上下文管理", comment: "")),
                footer: Text(NSLocalizedString("设置发送到模型的最近消息数量。例如，设置为10将只发送最后5条用户消息和5条AI回复。设置为0表示不限制。", comment: ""))
            ) {
                HStack {
                    Text(NSLocalizedString("最大上下文消息数", comment: ""))
                    Spacer()
                    TextField(NSLocalizedString("数量", comment: ""), value: $maxChatHistory, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
            }

            Section(
                header: Text(NSLocalizedString("性能设置", comment: "")),
                footer: Text(NSLocalizedString("设置进入历史会话时默认加载的最近对话轮次（从最近一条用户消息开始向后）。可以有效降低长对话的内存和性能开销。设置为0表示不启用此功能，将加载所有消息。", comment: ""))
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            ) {
                HStack {
                    Text(NSLocalizedString("懒加载轮次", comment: ""))
                    Spacer()
                    TextField(NSLocalizedString("数量", comment: ""), value: $lazyLoadMessageCount, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
            }
        }
        .navigationTitle(NSLocalizedString("偏好设置", comment: ""))
    }

    private func handleTemperatureChange(_ value: Double) {
        let roundedValue = (value * 100).rounded() / 100
        aiTemperature = roundedValue
        unlockTemperatureBoundaryAchievementIfNeeded(roundedValue)
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
            Form {
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
