// ============================================================================
// DailyPulseView.swift
// ============================================================================
// watchOS 每日脉冲视图
//
// 功能特性:
// - 展示每日脉冲卡片与核心状态
// - 支持手动生成、自动补生成、关注焦点输入
// - 支持卡片反馈、保存为会话与继续聊天
// ============================================================================

import SwiftUI
import MarkdownUI
import Shared

struct DailyPulseView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var pulseManager = DailyPulseManager.shared

    @State private var expandedCardIDs: Set<UUID> = []
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section("生成") {
                Toggle("自动补生成", isOn: $pulseManager.autoGenerateEnabled)

                if let run = pulseManager.latestRun {
                    Text(run.headline)
                        .font(.footnote.weight(.semibold))
                    Text(summaryText(for: run))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("还没有每日脉冲记录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task {
                        await pulseManager.generateNow()
                        if pulseManager.lastErrorMessage == nil {
                            statusMessage = "已尝试生成。"
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
            }

            Section("关注焦点") {
                TextField("例如：下一步要做什么", text: $pulseManager.focusText)
                if !pulseManager.focusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(role: .destructive) {
                        pulseManager.focusText = ""
                    } label: {
                        Label("清空", systemImage: "xmark.circle")
                    }
                }
            }

            if let run = pulseManager.latestRun {
                let visibleCards = run.visibleCards
                Section(run.dayKey == DailyPulseManager.dayKey(for: Date()) ? "今天的卡片" : "最近卡片") {
                    if visibleCards.isEmpty {
                        Text("这次卡片都被隐藏了，可以重新生成。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleCards) { card in
                            cardView(card, runID: run.id)
                        }
                    }
                }
            }
        }
        .navigationTitle("每日脉冲")
        .task {
            await pulseManager.generateIfNeeded()
        }
        .alert("每日脉冲", isPresented: alertBinding) {
            Button("好的", role: .cancel) {
                statusMessage = nil
                pulseManager.clearError()
            }
        } message: {
            Text(pulseManager.lastErrorMessage ?? statusMessage ?? "")
        }
    }

    private func cardView(_ card: DailyPulseCard, runID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.title)
                .font(.headline)
            Text(card.summary)
                .font(.footnote)
            Text(card.whyRecommended)
                .font(.caption2)
                .foregroundStyle(.secondary)

            DisclosureGroup(isExpanded: expansionBinding(for: card.id)) {
                Markdown(card.detailsMarkdown)
                    .font(.footnote)
                    .padding(.top, 4)
            } label: {
                Label("展开详情", systemImage: "doc.text")
            }

            if card.savedSessionID != nil {
                Label("已保存为会话", systemImage: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }

            Button {
                if viewModel.saveDailyPulseCard(card, from: runID) != nil {
                    statusMessage = card.savedSessionID == nil ? "已保存为会话。" : "已打开已保存会话。"
                }
            } label: {
                Label(card.savedSessionID == nil ? "保存为会话" : "打开会话", systemImage: card.savedSessionID == nil ? "square.and.arrow.down" : "bubble.left.and.bubble.right")
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.continueDailyPulseCard(card, from: runID)
                statusMessage = "已写入聊天输入框，返回上一层即可继续。"
            } label: {
                Label("继续聊", systemImage: "arrow.up.right.circle")
            }
            .buttonStyle(.borderedProminent)

            HStack {
                Button {
                    pulseManager.applyFeedback(.liked, cardID: card.id, runID: runID)
                } label: {
                    Image(systemName: card.feedback == .liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .tint(.pink)

                Button {
                    pulseManager.applyFeedback(.disliked, cardID: card.id, runID: runID)
                } label: {
                    Image(systemName: card.feedback == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                .tint(.orange)

                Button(role: .destructive) {
                    pulseManager.applyFeedback(.hidden, cardID: card.id, runID: runID)
                } label: {
                    Image(systemName: "eye.slash")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
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
        return "\(dateText) · \(run.visibleCards.count)/\(run.cards.count) 张可见"
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
