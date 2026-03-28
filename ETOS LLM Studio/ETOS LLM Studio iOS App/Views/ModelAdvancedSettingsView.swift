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
    @Binding var enableAutoSessionNaming: Bool
    @Binding var currentSession: ChatSession?
    @Binding var includeSystemTimeInPrompt: Bool

    let addGlobalSystemPromptEntry: () -> Void
    let selectGlobalSystemPromptEntry: (UUID?) -> Void
    let updateSelectedGlobalSystemPromptTitle: (String) -> Void
    let updateSelectedGlobalSystemPromptContent: (String) -> Void
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

    private var selectedGlobalPromptTitleBinding: Binding<String> {
        Binding(
            get: { selectedGlobalPromptEntry?.title ?? "" },
            set: { updateSelectedGlobalSystemPromptTitle($0) }
        )
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
                HStack {
                    Button {
                        addGlobalSystemPromptEntry()
                    } label: {
                        Label("新增提示词", systemImage: "plus")
                    }

                    Spacer()

                    if let selectedID = selectedGlobalSystemPromptEntryID {
                        Button(role: .destructive) {
                            deleteGlobalSystemPromptEntry(selectedID)
                        } label: {
                            Label("删除当前", systemImage: "trash")
                        }
                    }
                }

                if globalSystemPromptEntries.isEmpty {
                    Text("暂无提示词，点击“新增提示词”创建。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(globalSystemPromptEntries) { entry in
                        Button {
                            selectGlobalSystemPromptEntry(entry.id)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(displayTitle(for: entry))
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(displayPreview(for: entry))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if selectedGlobalSystemPromptEntryID == entry.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete(perform: deleteGlobalPromptRows)
                }

                if selectedGlobalPromptEntry != nil {
                    TextField("提示词名称", text: selectedGlobalPromptTitleBinding)
                    TextField("自定义全局系统提示词", text: selectedGlobalPromptContentBinding, axis: .vertical)
                        .lineLimit(3...8)

                    Text("当前提示词内容为空时，不会发送全局系统提示词。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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

            Section("输出样式") {
                Toggle("自动生成话题标题", isOn: $enableAutoSessionNaming)
                Toggle("启用流式输出", isOn: $enableStreaming)
            }

            Section {
                Toggle(NSLocalizedString("启用响应测速", comment: "Enable response speed metrics"), isOn: $enableResponseSpeedMetrics)
            } header: {
                Text(NSLocalizedString("响应测速", comment: "Response speed metrics section title"))
            } footer: {
                Text(NSLocalizedString("开启后会记录单次 API 请求的总回复时间；流式时还会记录首字时间和 token/s。", comment: "Response speed metrics description"))
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

    private func deleteGlobalPromptRows(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            guard globalSystemPromptEntries.indices.contains(index) else { continue }
            let entryID = globalSystemPromptEntries[index].id
            deleteGlobalSystemPromptEntry(entryID)
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
