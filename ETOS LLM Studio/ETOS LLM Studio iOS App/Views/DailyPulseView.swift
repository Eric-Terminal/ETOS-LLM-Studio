// ============================================================================
// DailyPulseView.swift
// ============================================================================
// iOS 每日脉冲视图
//
// 功能特性:
// - 展示每日脉冲卡片列表与详情
// - 提供手动生成、自动补生成开关与关注焦点输入
// - 支持卡片反馈、保存为会话与继续聊天
// ============================================================================

import SwiftUI
import MarkdownUI
import Shared

struct DailyPulseView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var pulseManager = DailyPulseManager.shared

    @State private var expandedCardIDs: Set<UUID> = []
    @State private var statusMessage: String?

    var body: some View {
        List {
            generationSection
            focusSection
            externalSourcesSection
            latestPulseSection
        }
        .navigationTitle("每日脉冲")
        .navigationBarTitleDisplayMode(.inline)
        .alert("每日脉冲", isPresented: alertBinding) {
            Button("知道了", role: .cancel) {
                statusMessage = nil
                pulseManager.clearError()
            }
        } message: {
            Text(pulseManager.lastErrorMessage ?? statusMessage ?? "")
        }
        .task {
            await pulseManager.generateIfNeeded()
        }
    }

    private var generationSection: some View {
        Section("生成") {
            Toggle("每日首次打开自动补生成", isOn: $pulseManager.autoGenerateEnabled)

            if let run = pulseManager.latestRun {
                VStack(alignment: .leading, spacing: 6) {
                    Text(run.headline)
                        .font(.headline)
                    Text(summaryText(for: run))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                Text("还没有每日脉冲记录。你可以先手动生成一份今天的主动情报卡片。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    await pulseManager.generateNow()
                    if pulseManager.lastErrorMessage == nil {
                        statusMessage = "已尝试生成最新的每日脉冲。"
                    }
                }
            } label: {
                HStack {
                    Label("立即生成", systemImage: "sparkles")
                    Spacer()
                    if pulseManager.isGenerating {
                        ProgressView()
                    }
                }
            }
            .disabled(pulseManager.isGenerating)
        } footer: {
            Text("当前会优先使用最近聊天、长期记忆、请求日志、反馈历史和你的关注焦点，并可选结合 MCP / 快捷指令能力生成约 3 张卡片。")
        }
    }

    private var focusSection: some View {
        Section("关注焦点") {
            TextField("例如：继续推进某个项目、帮我整理下一步、关注最近反复提到的话题", text: $pulseManager.focusText, axis: .vertical)
                .lineLimit(2...4)

            if !pulseManager.focusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(role: .destructive) {
                    pulseManager.focusText = ""
                } label: {
                    Label("清空关注焦点", systemImage: "xmark.circle")
                }
            }
        } footer: {
            Text("这里的内容会参与下一次每日脉冲生成，用来告诉 AI 你最近最想优先看的方向。")
        }
    }

    private var externalSourcesSection: some View {
        Section("外部上下文") {
            Toggle("纳入 MCP 服务器能力", isOn: $pulseManager.includeMCPContext)
            Toggle("纳入快捷指令能力", isOn: $pulseManager.includeShortcutContext)
            Toggle("纳入最近外部结果", isOn: $pulseManager.includeRecentExternalResults)
        } footer: {
            Text("前两项会纳入可调用能力描述；“最近外部结果”则会纳入你最近一次 MCP 调试输出或快捷指令执行结果摘要，它们更接近已经获取到的真实外部内容。")
        }
    }

    @ViewBuilder
    private var latestPulseSection: some View {
        if let run = pulseManager.latestRun {
            let visibleCards = run.visibleCards
            Section(run.dayKey == DailyPulseManager.dayKey(for: Date()) ? "今天的卡片" : "最近一次卡片") {
                if visibleCards.isEmpty {
                    Text("这次生成的卡片都被你隐藏了。你可以重新生成一份新的每日脉冲。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleCards) { card in
                        cardView(card, runID: run.id)
                    }
                }
            } footer: {
                Text(summaryText(for: run))
            }
        } else {
            Section("卡片") {
                Text("暂时没有可展示的每日脉冲。先去聊几轮，或者写一点关注焦点，再回来生成会更准。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cardView(_ card: DailyPulseCard, runID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(card.title)
                        .font(.headline)
                    Spacer()
                    feedbackBadge(for: card)
                }

                Text(card.summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Text(card.whyRecommended)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: expansionBinding(for: card.id)) {
                Markdown(card.detailsMarkdown)
                    .font(.subheadline)
                    .padding(.top, 6)
            } label: {
                Label("展开详情", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    feedbackButton(title: "喜欢", systemImage: card.feedback == .liked ? "hand.thumbsup.fill" : "hand.thumbsup") {
                        pulseManager.applyFeedback(.liked, cardID: card.id, runID: runID)
                    }

                    feedbackButton(title: "暂不感兴趣", systemImage: card.feedback == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                        pulseManager.applyFeedback(.disliked, cardID: card.id, runID: runID)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        if viewModel.saveDailyPulseCard(card, from: runID) != nil {
                            statusMessage = card.savedSessionID == nil ? "已将这张卡片保存为正式会话。" : "已跳转到之前保存的会话。"
                        }
                    } label: {
                        Label(card.savedSessionID == nil ? "保存为会话" : "打开会话", systemImage: card.savedSessionID == nil ? "square.and.arrow.down" : "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        viewModel.continueDailyPulseCard(card, from: runID)
                        statusMessage = "已把这张卡片放进聊天上下文，并为你填好继续追问。"
                    } label: {
                        Label("继续聊", systemImage: "arrow.up.right.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(role: .destructive) {
                    pulseManager.applyFeedback(.hidden, cardID: card.id, runID: runID)
                } label: {
                    Label("隐藏这张卡片", systemImage: "eye.slash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 6)
    }

    private func feedbackButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func feedbackBadge(for card: DailyPulseCard) -> some View {
        switch card.feedback {
        case .liked:
            Label("已喜欢", systemImage: "heart.fill")
                .font(.caption)
                .foregroundStyle(.pink)
        case .disliked:
            Label("已降权", systemImage: "hand.thumbsdown.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .hidden:
            Label("已隐藏", systemImage: "eye.slash.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .none:
            if card.savedSessionID != nil {
                Label("已保存", systemImage: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
    }

    private func expansionBinding(for cardID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedCardIDs.contains(cardID) },
            set: { isExpanded in
                if isExpanded {
                    expandedCardIDs.insert(cardID)
                } else {
                    expandedCardIDs.remove(cardID)
                }
            }
        )
    }

    private func summaryText(for run: DailyPulseRun) -> String {
        let dateText = run.generatedAt.formatted(date: .abbreviated, time: .shortened)
        return "生成于 \(dateText) · 可见卡片 \(run.visibleCards.count)/\(run.cards.count)"
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: {
                let error = pulseManager.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let info = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !error.isEmpty || !info.isEmpty
            },
            set: { isPresented in
                guard !isPresented else { return }
                statusMessage = nil
                pulseManager.clearError()
            }
        )
    }
}
