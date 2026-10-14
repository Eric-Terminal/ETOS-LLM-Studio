import ETOSCore
import SwiftUI

@MainActor
struct MacDailyPulseCardView: View {
    @ObservedObject var model: MacDailyPulseModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsGuide = false
    @State private var visible = false
    private var card: MacDailyPulsePresentation.Card? {
        guard let id = model.selectedCardID else { return nil }
        return model.presentation?.cards[id]
    }

    var body: some View {
        NavigationStack {
            Form {
                if let card {
                    Section {
                        Text(card.source.title).font(.headline)
                        Text(card.source.summary).textSelection(.enabled)
                        Text(card.feedbackTitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Section(NSLocalizedString("为什么推荐给你", comment: "")) {
                        Text(card.source.whyRecommended).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Section(NSLocalizedString("详情", comment: "")) { MacMessageTextView(text: card.detail) }
                    if !card.source.suggestedPrompt.isEmpty {
                        Section(NSLocalizedString("建议追问", comment: "")) { Text(card.source.suggestedPrompt).textSelection(.enabled) }
                    }
                    Section(NSLocalizedString("操作", comment: "")) {
                        Button(NSLocalizedString("继续聊", comment: "")) { model.save(card, continueChat: true) }
                        Button(card.source.savedSessionID == nil ? NSLocalizedString("保存为会话", comment: "") : NSLocalizedString("已保存为会话", comment: "")) {
                            model.save(card, continueChat: false)
                        }
                        Button(card.taskID == nil ? NSLocalizedString("加入 Pulse 任务", comment: "") : NSLocalizedString("已在 Pulse 任务中", comment: "")) {
                            model.addTask(card)
                        }.disabled(card.taskID != nil)
                        Button(NSLocalizedString("喜欢", comment: "")) { model.feedback(.liked, card: card) }
                        Button(NSLocalizedString("降权", comment: "")) { model.feedback(.disliked, card: card) }
                        Button(NSLocalizedString("隐藏", comment: "")) { model.feedback(.hidden, card: card) }
                        Button(NSLocalizedString("重置反馈", comment: "")) { model.feedback(.none, card: card) }
                    }.disabled(!model.canEdit || model.isPreparing)
                } else if model.presentation == nil || model.isPreparing { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                else { Text(NSLocalizedString("这张卡片已不可用。", comment: "")).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("每日脉冲", comment: ""))
            .toolbar {
                if model.isWorking { ProgressView().controlSize(.small) }
                Button { showsGuide.toggle() } label: { Label(NSLocalizedString("页面向导", comment: ""), systemImage: "sparkles") }
                Button(NSLocalizedString("完成", comment: "")) { dismiss() }
            }
            .inspector(isPresented: $showsGuide) { MacGuideView().inspectorColumnWidth(min: 300, ideal: 360, max: 500) }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-pulse-card-\(model.selectedCardID?.uuidString ?? "none")-\(model.revision)"),
                title: NSLocalizedString("每日脉冲", comment: ""),
                documents: [GuideDocumentReference(id: "daily-pulse", title: "Daily Pulse")],
                isActive: visible && model.canEdit && !model.isPreparing && card != nil,
                settings: [
                    .readOnly("card_id", label: NSLocalizedString("卡片", comment: ""), value: { .string(card?.id.uuidString ?? "") }),
                    .readOnly("title", label: NSLocalizedString("标题", comment: ""), value: { .string(card?.source.title ?? "") }),
                    .readOnly("feedback", label: NSLocalizedString("反馈", comment: ""), value: { .string(card?.source.feedback.rawValue ?? "none") }),
                    .readOnly("saved_session_id", label: NSLocalizedString("会话", comment: ""), value: { .string(card?.source.savedSessionID?.uuidString ?? "") })
                ])
        }
        .frame(minWidth: 600, minHeight: 480)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}
