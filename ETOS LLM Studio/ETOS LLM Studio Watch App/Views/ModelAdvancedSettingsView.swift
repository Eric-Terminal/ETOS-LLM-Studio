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
            Section(header: Text("全局系统提示词")) {
                TextField("自定义全局系统提示词", text: selectedGlobalPromptContentBinding.watchKeyboardNewlineBinding(), axis: .vertical)
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
                        Text("提示词列表")
                        Spacer()
                        Text(displayTitle(for: selectedGlobalPromptEntry))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text("在二级菜单中可右滑删除、左滑更多（编辑），点选条目会自动返回。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("当前话题提示词"), footer: Text("仅对当前对话生效。")) {
                TextField("自定义话题提示词", text: Binding(
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

            Section(header: Text("增强提示词"), footer: Text("该提示词会附加在您的最后一条消息末尾，以增强指令效果。")) {
                TextField("自定义增强提示词", text: Binding(
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
                header: Text("系统时间注入"),
                footer: Text("开启后会在系统提示中插入 <time> 块，提供当前时间线索。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            ) {
                Toggle("发送系统时间", isOn: $includeSystemTimeInPrompt)
            }

            Section(
                footer: Text("开启后会按时间窗口在历史消息中自动插入一条 system 路标，提示对应位置的请求时间。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            ) {
                Toggle("周期性时间路标", isOn: $enablePeriodicTimeLandmark)
                HStack {
                    Text("路标时间（分钟）")
                    Spacer()
                    TextField("分钟", value: $periodicTimeLandmarkIntervalMinutes, formatter: numberFormatter)
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

            Section(header: Text("会话设置")) {
                Toggle("启动时打开历史会话", isOn: $restoreLastSessionOnLaunch)
                Toggle("自动生成话题标题", isOn: $enableAutoSessionNaming)
            }

            Section(
                header: Text("思考内容"),
                footer: Text("开启后会在思考完成后异步生成一行摘要，并显示在思考耗时后面。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            ) {
                Toggle("启用思考摘要", isOn: $enableReasoningSummary)
            }

            Section(header: Text("输出设置")) {
                Toggle("流式输出", isOn: $enableStreaming)
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

            Section(header: Text("参数调整")) {
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
                header: Text("上下文管理"),
                footer: Text("设置发送到模型的最近消息数量。例如，设置为10将只发送最后5条用户消息和5条AI回复。设置为0表示不限制。")
            ) {
                HStack {
                    Text("最大上下文消息数")
                    Spacer()
                    TextField("数量", value: $maxChatHistory, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
            }

            Section(
                header: Text("性能设置"),
                footer: Text("设置进入历史会话时默认加载的最近对话轮次（从最近一条用户消息开始向后）。可以有效降低长对话的内存和性能开销。设置为0表示不启用此功能，将加载所有消息。")
                    .etFont(.footnote)
                    .foregroundColor(.secondary)
            ) {
                HStack {
                    Text("懒加载轮次")
                    Spacer()
                    TextField("数量", value: $lazyLoadMessageCount, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
            }
        }
        .navigationTitle("偏好设置")
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
        guard let entry else { return "未选择" }
        let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "未命名提示词" : trimmedTitle
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
                    Label("新增提示词", systemImage: "plus")
                }
            }

            Section("全局系统提示词") {
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
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            editingEntry = entry
                        } label: {
                            Label("更多", systemImage: "ellipsis.circle")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .navigationTitle("全局提示词")
        .sheet(item: $editingEntry) { entry in
            GlobalSystemPromptEditorView(entry: entry) { title, content in
                updateGlobalSystemPromptEntry(entry.id, title, content)
            }
        }
    }

    private func displayTitle(for entry: GlobalSystemPromptEntry) -> String {
        let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "未命名提示词" : trimmedTitle
    }

    private func displayPreview(for entry: GlobalSystemPromptEntry) -> String {
        let trimmedContent = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContent.isEmpty {
            return "空提示词（不发送）"
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
                TextField("提示词名称", text: $title.watchKeyboardNewlineBinding())
                TextField("提示词内容", text: $content.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(4...10)

                Button("保存修改") {
                    onSave(title, content)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .navigationTitle("编辑提示词")
        }
    }
}
