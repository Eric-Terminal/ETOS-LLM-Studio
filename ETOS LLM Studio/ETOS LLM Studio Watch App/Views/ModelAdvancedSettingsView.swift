// ============================================================================
// ModelAdvancedSettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 高级模型设置视图
//
// 功能特性:
// - 调整 Temperature, Top P, System Prompt 等参数
// - 管理上下文和懒加载数量
// ============================================================================

import SwiftUI
import Foundation
import Shared

/// 高级模型设置视图
struct ModelAdvancedSettingsView: View {

    // MARK: - 绑定

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

    // MARK: - 视图主体

    var body: some View {
        Form {
            Section(header: Text("全局系统提示词")) {
                Button {
                    addGlobalSystemPromptEntry()
                } label: {
                    Label("新增提示词", systemImage: "plus")
                }

                if let selectedID = selectedGlobalSystemPromptEntryID {
                    Button(role: .destructive) {
                        deleteGlobalSystemPromptEntry(selectedID)
                    } label: {
                        Label("删除当前", systemImage: "trash")
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
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayTitle(for: entry))
                                        .lineLimit(1)
                                    Text(displayPreview(for: entry))
                                        .font(.caption2)
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
                    }
                }

                if selectedGlobalPromptEntry != nil {
                    TextField("提示词名称", text: selectedGlobalPromptTitleBinding.watchKeyboardNewlineBinding())
                    TextField("自定义全局系统提示词", text: selectedGlobalPromptContentBinding.watchKeyboardNewlineBinding(), axis: .vertical)
                        .lineLimit(5...10)

                    Text("当前提示词内容为空时，不会发送全局系统提示词。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                    .font(.footnote)
                    .foregroundColor(.secondary)
            ) {
                Toggle("发送系统时间", isOn: $includeSystemTimeInPrompt)
            }

            Section(header: Text("会话设置")) {
                Toggle("自动生成话题标题", isOn: $enableAutoSessionNaming)
            }

            Section(header: Text("输出设置")) {
                Toggle("流式输出", isOn: $enableStreaming)
            }

            Section(
                header: Text(NSLocalizedString("响应测速", comment: "Response speed metrics section title")),
                footer: Text(NSLocalizedString("开启后会记录单次 API 请求的总回复时间；流式时还会记录首字时间和 token/s。", comment: "Response speed metrics description"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            ) {
                Toggle(NSLocalizedString("启用响应测速", comment: "Enable response speed metrics"), isOn: $enableResponseSpeedMetrics)
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
                            aiTemperature = (aiTemperature * 100).rounded() / 100
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
                    .font(.footnote)
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
        .navigationTitle("高级模型设置")
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
