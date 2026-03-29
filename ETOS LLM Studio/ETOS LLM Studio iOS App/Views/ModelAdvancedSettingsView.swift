// ============================================================================
// ModelAdvancedSettingsView.swift
// ============================================================================
// ModelAdvancedSettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Shared

struct ModelAdvancedSettingsView: View {
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
    @Binding var currentSession: ChatSession?
    @Binding var includeSystemTimeInPrompt: Bool
    @Binding var enablePeriodicTimeLandmark: Bool
    @Binding var periodicTimeLandmarkIntervalMinutes: Int

    let addGlobalSystemPromptEntry: () -> Void
    let selectGlobalSystemPromptEntry: (UUID?) -> Void
    let updateSelectedGlobalSystemPromptContent: (String) -> Void
    let updateGlobalSystemPromptEntry: (UUID, String, String) -> Void
    let deleteGlobalSystemPromptEntry: (UUID) -> Void

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

    var body: some View {
        Form {
            Section("全局系统提示词") {
                TextField("自定义全局系统提示词", text: selectedGlobalPromptContentBinding, axis: .vertical)
                    .lineLimit(3...8)
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
                    LabeledContent("提示词列表") {
                        Text(displayTitle(for: selectedGlobalPromptEntry))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("为空时不会发送全局系统提示词。选择器中可右滑删除、左滑更多（编辑），点选条目会自动返回。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("当前会话提示词") {
                TextField("话题提示词", text: Binding(
                    get: { currentSession?.topicPrompt ?? "" },
                    set: { newValue in
                        if var session = currentSession {
                            session.topicPrompt = newValue
                            currentSession = session
                            ChatService.shared.updateSession(session)
                        }
                    }
                ), axis: .vertical)
                .lineLimit(2...6)

                TextField("增强提示词", text: Binding(
                    get: { currentSession?.enhancedPrompt ?? "" },
                    set: { newValue in
                        if var session = currentSession {
                            session.enhancedPrompt = newValue
                            currentSession = session
                            ChatService.shared.updateSession(session)
                        }
                    }
                ), axis: .vertical)
                .lineLimit(2...6)
            }

            Section {
                Toggle("发送系统时间", isOn: $includeSystemTimeInPrompt)
            } header: {
                Text("系统时间注入")
            } footer: {
                Text("开启后会在系统提示中注入 <time> 标签，并包含当前设备时间。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("周期性时间路标", isOn: $enablePeriodicTimeLandmark)
                LabeledContent("路标时间（分钟）") {
                    TextField("分钟", value: $periodicTimeLandmarkIntervalMinutes, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .disabled(!enablePeriodicTimeLandmark)
                }
            } footer: {
                Text("开启后会按时间窗口在历史消息中自动插入一条 system 路标，提示对应位置的请求时间。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: periodicTimeLandmarkIntervalMinutes) { _, newValue in
                if newValue < 1 {
                    periodicTimeLandmarkIntervalMinutes = 1
                }
            }

            Section("输出样式") {
                Toggle("自动生成话题标题", isOn: $enableAutoSessionNaming)
                Toggle("启用流式输出", isOn: $enableStreaming)
            }

            Section {
                Toggle(NSLocalizedString("启用响应测速", comment: "Enable response speed metrics"), isOn: $enableResponseSpeedMetrics)
                Toggle(NSLocalizedString("流式附带官方 Token 用量", comment: "Enable stream include usage in OpenAI-compatible requests"), isOn: $enableOpenAIStreamIncludeUsage)
            } header: {
                Text(NSLocalizedString("响应测速", comment: "Response speed metrics section title"))
            } footer: {
                Text(
                    "\(NSLocalizedString("开启后会记录单次 API 请求的总回复时间；流式时还会记录首字时间和 token/s。", comment: "Response speed metrics description"))\n\n\(NSLocalizedString("“流式附带官方 Token 用量”会在 OpenAI 兼容流式请求中发送 stream_options.include_usage=true，部分平台若不兼容可关闭。", comment: "OpenAI stream include usage description"))"
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("采样参数") {
                VStack(alignment: .leading) {
                    Text("Temperature \(String(format: "%.2f", aiTemperature))")
                        .font(.subheadline)
                    Slider(value: $aiTemperature, in: 0...2, step: 0.05)
                        .onChange(of: aiTemperature) { _, value in
                            aiTemperature = (value * 100).rounded() / 100
                        }
                }

                VStack(alignment: .leading) {
                    Text("Top P \(String(format: "%.2f", aiTopP))")
                        .font(.subheadline)
                    Slider(value: $aiTopP, in: 0...1, step: 0.05)
                        .onChange(of: aiTopP) { _, value in
                            aiTopP = (value * 100).rounded() / 100
                        }
                }
            }

            Section("上下文与懒加载") {
                LabeledContent("最大上下文消息数") {
                    TextField("数量", value: $maxChatHistory, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }

                LabeledContent("懒加载轮次") {
                    TextField("数量", value: $lazyLoadMessageCount, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }

                Text("设置进入历史会话时默认加载的最近对话轮次（从最近一条用户消息开始向后）。数值越小，长对话加载越快；设置为 0 表示加载全部历史。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("高级模型设置")
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
                            VStack(alignment: .leading, spacing: 4) {
                                Text(displayTitle(for: entry))
                                    .lineLimit(1)
                                Text(displayPreview(for: entry))
                                    .font(.footnote)
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
                    .contextMenu {
                        Button {
                            editingEntry = entry
                        } label: {
                            Label("编辑", systemImage: "square.and.pencil")
                        }
                        Button(role: .destructive) {
                            deleteGlobalSystemPromptEntry(entry.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
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
                TextField("提示词名称", text: $title)
                TextField("提示词内容", text: $content, axis: .vertical)
                    .lineLimit(4...10)
            }
            .navigationTitle("编辑提示词")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(title, content)
                        dismiss()
                    }
                }
            }
        }
    }
}
