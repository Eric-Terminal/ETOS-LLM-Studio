import ETOSCore
import SwiftUI

@MainActor
struct MacDailyPulseEntry: View {
    @ObservedObject var model: MacDailyPulseModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    var body: some View {
        Button { model.showsWindow = true } label: {
            Label(NSLocalizedString("每日脉冲", comment: ""), systemImage: "rectangle.stack")
        }
        .disabled(!workspace.canManageLocalModels)
    }
}

@MainActor
struct MacDailyPulseHost: ViewModifier {
    @ObservedObject var model: MacDailyPulseModel
    func body(content: Content) -> some View {
        content.sheet(isPresented: $model.showsWindow) { MacDailyPulseView(model: model) }
    }
}

@MainActor
struct MacDailyPulseView: View {
    private enum Tab: String { case cards, tasks, feedback, signals, settings }
    @ObservedObject var model: MacDailyPulseModel
    var isEmbeddedInSettings = false
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var appLock = AppLockManager.shared
    @State private var tab = Tab.cards
    @State private var visible = false
    @State private var showsGuide = false
    @State private var deletion: MacDailyPulseModel.Deletion?
    private var available: Bool { visible && workspace.canManageLocalModels && appLock.state != .locked }

    var body: some View {
        NavigationStack {
            Group {
                if available, let snapshot = model.presentation, let manager = model.manager, let delivery = model.delivery {
                    TabView(selection: $tab) {
                        cards(snapshot).tabItem { Label(NSLocalizedString("卡片", comment: ""), systemImage: "rectangle.stack") }.tag(Tab.cards)
                        tasks(snapshot).tabItem { Label(NSLocalizedString("任务", comment: ""), systemImage: "checklist") }.tag(Tab.tasks)
                        feedback(snapshot).tabItem { Label(NSLocalizedString("反馈历史", comment: ""), systemImage: "clock.arrow.circlepath") }.tag(Tab.feedback)
                        signals(snapshot).tabItem { Label(NSLocalizedString("外部信号", comment: ""), systemImage: "antenna.radiowaves.left.and.right") }.tag(Tab.signals)
                        MacDailyPulseSettingsView(model: model, manager: manager, delivery: delivery,
                            snapshot: snapshot, isActive: available && tab == .settings)
                            .tabItem { Label(NSLocalizedString("设置", comment: ""), systemImage: "gearshape") }.tag(Tab.settings)
                    }
                } else { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
            }
            .navigationTitle(NSLocalizedString("每日脉冲", comment: ""))
            .toolbar {
                if model.isWorking {
                    ProgressView().controlSize(.small)
                    if model.manager?.isGenerating == true {
                        Button(NSLocalizedString("停止生成", comment: "")) { model.cancelGeneration() }
                    }
                } else {
                    Button(NSLocalizedString("立即生成", comment: "")) { model.generate(.manual) }
                        .disabled(!available || !model.canEdit || model.manager?.isDailyPulseEnabled != true)
                }
                Button { showsGuide.toggle() } label: { Label(NSLocalizedString("页面向导", comment: ""), systemImage: "sparkles") }
                if !isEmbeddedInSettings {
                    Button(NSLocalizedString("完成", comment: "")) { model.showsWindow = false }
                }
            }
            .inspector(isPresented: $showsGuide) { MacGuideView().inspectorColumnWidth(min: 300, ideal: 360, max: 500) }
            .confirmationDialog(NSLocalizedString("确认删除", comment: ""), isPresented: Binding(
                get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
                    Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                        if let deletion { model.delete(deletion) }
                        deletion = nil
                    }
                }
            .alert(NSLocalizedString("每日脉冲", comment: ""), isPresented: Binding(
                get: { model.manager?.lastErrorMessage != nil },
                set: { if !$0 { model.manager?.clearError() } })) {
                    Button(NSLocalizedString("知道了", comment: "")) { model.manager?.clearError() }
                } message: { Text(model.manager?.lastErrorMessage ?? "") }
            .sheet(isPresented: Binding(get: { model.selectedCardID != nil }, set: { if !$0 { model.selectedCardID = nil } })) {
                MacDailyPulseCardView(model: model)
            }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-daily-pulse-\(tab.rawValue)-\(model.revision)"),
                title: NSLocalizedString("每日脉冲", comment: ""),
                documents: [GuideDocumentReference(id: "daily-pulse", title: "Daily Pulse")],
                isActive: available && tab != .settings && !model.isPreparing && model.presentation != nil,
                settings: [
                    .readOnly("tab", label: NSLocalizedString("当前页面", comment: ""), value: { .string(tab.rawValue) }),
                    .readOnly("summary", label: NSLocalizedString("概览", comment: ""), value: { model.presentation?.guideSummary ?? .null })
                ])
        }
        .frame(minWidth: 700, minHeight: 560)
        .onAppear { visible = true; model.setPresenting(available) }
        .onDisappear { visible = false; model.setPresenting(false) }
        .onChange(of: available) { _, value in model.setPresenting(value); if !value { deletion = nil } }
        .onChange(of: tab) { old, _ in if old == .settings { model.generate(.scheduled) } }
    }

    private func cards(_ snapshot: MacDailyPulsePresentation) -> some View {
        List {
            Section {
                MacSettingsIntroCard(id: "daily-pulse", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 每日脉冲使用说明", comment: ""), documentID: "daily-pulse",
                    isActive: workspace.canManageLocalModels && appLock.state != .locked)
            }
            if let run = snapshot.today { runSection(run) }
            else { Text(NSLocalizedString("今天还没有卡片", comment: "")).foregroundStyle(.secondary) }
        }
    }

    private func runSection(_ run: MacDailyPulsePresentation.Run) -> some View {
        Section {
            Text(run.headline).font(.headline)
            ForEach(run.visibleCards) { card in cardButton(card) }
            if !run.hiddenCards.isEmpty {
                DisclosureGroup(NSLocalizedString("已隐藏", comment: "")) {
                    ForEach(run.hiddenCards) { card in cardButton(card) }
                }
            }
        } header: { Text(run.day) } footer: { Text(run.date).font(.caption).foregroundStyle(.secondary) }
    }

    private func cardButton(_ card: MacDailyPulsePresentation.Card) -> some View {
        Button { model.selectedCardID = card.id } label: {
            VStack(alignment: .leading) {
                Text(card.source.title).font(.headline)
                Text(card.source.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                Text(card.feedbackTitle).font(.caption).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain)
    }

    private func tasks(_ snapshot: MacDailyPulsePresentation) -> some View {
        List {
            if snapshot.tasks.isEmpty { Text(NSLocalizedString("暂无任务", comment: "")).foregroundStyle(.secondary) }
            ForEach(snapshot.tasks) { row in
                Section {
                    Toggle(row.source.title, isOn: Binding(get: { row.source.isCompleted }, set: { _ in model.toggleTask(row.id) }))
                    Text(row.source.details).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    if !row.source.suggestedPrompt.isEmpty { Text(row.source.suggestedPrompt).textSelection(.enabled) }
                    Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deletion = .task(row.id) }
                } footer: { Text(row.date).font(.caption).foregroundStyle(.secondary) }
            }
            Button(NSLocalizedString("清理已完成任务", comment: ""), role: .destructive) { deletion = .completedTasks }
                .disabled(!snapshot.hasCompletedTasks)
        }.disabled(!model.canEdit || model.isPreparing)
    }

    private func feedback(_ snapshot: MacDailyPulsePresentation) -> some View {
        List {
            if snapshot.feedback.isEmpty { Text(NSLocalizedString("还没有反馈历史", comment: "")).foregroundStyle(.secondary) }
            ForEach(snapshot.feedback) { row in
                Section {
                    Text(row.source.cardTitle)
                    Text(row.title).font(.footnote).foregroundStyle(.secondary)
                    Text(row.source.topicHint).font(.caption).foregroundStyle(.secondary)
                    Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deletion = .feedback(row.id) }
                } footer: { Text(row.date).font(.caption).foregroundStyle(.secondary) }
            }
            Button(NSLocalizedString("清空反馈历史", comment: ""), role: .destructive) { deletion = .allFeedback }
                .disabled(snapshot.feedback.isEmpty)
        }.disabled(!model.canEdit || model.isPreparing)
    }

    private func signals(_ snapshot: MacDailyPulsePresentation) -> some View {
        List {
            if snapshot.signals.isEmpty { Text(NSLocalizedString("暂无外部信号", comment: "")).foregroundStyle(.secondary) }
            ForEach(snapshot.signals) { row in
                Section {
                    Text(row.source.title)
                    Text(row.source.preview).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    if row.source.isFailure { Label(NSLocalizedString("错误", comment: ""), systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                    Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deletion = .signal(row.id) }
                } footer: { Text(row.date).font(.caption).foregroundStyle(.secondary) }
            }
            Button(NSLocalizedString("清空外部信号", comment: ""), role: .destructive) { deletion = .allSignals }
                .disabled(snapshot.signals.isEmpty)
        }.disabled(!model.canEdit || model.isPreparing)
    }
}
