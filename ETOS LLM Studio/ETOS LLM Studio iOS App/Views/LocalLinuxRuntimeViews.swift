// ============================================================================
// LocalLinuxRuntimeViews.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 用户终端、任务、recipe 与 guest 文件浏览器。
// ============================================================================

import ETOSCore
import SwiftUI
import UIKit

struct LocalLinuxResourceStatusSection: View {
    @ObservedObject private var monitor = LocalResourceUsageMonitor.shared

    var body: some View {
        Section {
            LabeledContent(
                NSLocalizedString("当前 App 进程", comment: "Local Linux process resource usage"),
                value: monitor.snapshot.displayText
            )
        } header: {
            Text(NSLocalizedString("资源状态", comment: "Local Linux resource status"))
        }
        .task {
            while !Task.isCancelled {
                await monitor.refresh()
                try? await Task<Never, Never>.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

struct LocalLinuxTerminalView: View {
    let initialJobID: UUID?
    let startupInput: Data?
    let requestedTitle: String?

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var job: LocalLinuxJob?
    @State private var terminalJobs: [LocalLinuxJob] = []
    @State private var inputOwner: LocalLinuxTerminalInputOwner?
    @State private var terminalShortcuts = LocalLinuxTerminalShortcutConfiguration.defaults
    @State private var output = LocalLinuxTerminalPresentation.empty
    @State private var input = ""
    @State private var errorMessage: String?
    @State private var outputTask: Task<Void, Never>?
    @State private var didSendStartupInput = false

    init(
        initialJobID: UUID? = nil,
        startupInput: Data? = nil,
        title: String? = nil
    ) {
        self.initialJobID = initialJobID
        self.startupInput = startupInput
        self.requestedTitle = title
    }

    var body: some View {
        VStack {
            installationStatusBar

            GeometryReader { proxy in
                ScrollView {
                    Group {
                        if output.plainText.isEmpty {
                            Text(NSLocalizedString("终端正在启动…", comment: "Linux terminal starting placeholder"))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(output.attributedText)
                        }
                    }
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(terminalCanvasColor)
                .defaultScrollAnchor(.bottom)
                .onAppear { resize(for: proxy.size) }
                .onChange(of: proxy.size) { _, size in resize(for: size) }
            }

            if isInputControlledByAgent {
                Text(NSLocalizedString("输入由 Agent 控制；发送内容即可接管", comment: "Terminal input controlled by Agent"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !terminalShortcuts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(terminalShortcuts) { shortcut in
                            terminalKey(shortcut)
                        }
                    }
                    .padding(.horizontal)
                }
            }

            HStack {
                TextField(NSLocalizedString("输入命令或终端内容", comment: "Linux terminal input"), text: $input)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(sendInput)
                Button(action: sendInput) {
                    Image(systemName: "return")
                }
                .accessibilityLabel(NSLocalizedString("发送到终端", comment: "Send terminal input"))
                .disabled(!isTerminalActive)
            }
            .padding()
        }
        .background(terminalCanvasColor.ignoresSafeArea())
        .navigationTitle(requestedTitle ?? NSLocalizedString("终端", comment: "Linux terminal title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Menu {
                        ForEach(terminalJobs) { terminal in
                            Button(terminalLabel(terminal)) { attach(to: terminal) }
                        }
                        Divider()
                        Button(NSLocalizedString("新建终端", comment: "Create Linux terminal")) {
                            Task { await createTerminal() }
                        }
                    } label: {
                        Label(
                            NSLocalizedString("切换或新建终端", comment: "Switch or create Linux terminal"),
                            systemImage: "rectangle.stack"
                        )
                    }

                    if inputOwner == .user, job?.runID != nil {
                        Button(action: returnInputToAgent) {
                            Label(
                                NSLocalizedString("将输入交还 Agent", comment: "Return terminal input to Agent"),
                                systemImage: "person.badge.clock"
                            )
                        }
                    }

                    Divider()
                    Button(action: interruptForegroundProgram) {
                        Label(
                            NSLocalizedString("中断前台程序", comment: "Interrupt terminal"),
                            systemImage: "exclamationmark"
                        )
                    }
                    .disabled(!isTerminalActive)

                    Button(role: .destructive) {
                        guard let job else { return }
                        Task { await LocalLinuxJobScheduler.shared.cancel(jobID: job.id) }
                    } label: {
                        Label(
                            NSLocalizedString("结束终端", comment: "Cancel terminal"),
                            systemImage: "stop.fill"
                        )
                    }
                    .disabled(!isTerminalActive)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(NSLocalizedString("终端操作", comment: "Terminal actions menu"))
            }
        }
        .task { await openInitialTerminal() }
        .onAppear(perform: reloadTerminalShortcuts)
        .onChange(of: appConfig.localLinuxTerminalShortcutIDs) { _, _ in
            reloadTerminalShortcuts()
        }
        .onChange(of: colorScheme) { _, _ in
            guard let job else { return }
            attach(to: job)
        }
        .onDisappear {
            // 离开页面只停止界面订阅，终端本身继续运行。
            outputTask?.cancel()
        }
        .alert(NSLocalizedString("终端错误", comment: "Linux terminal error"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(NSLocalizedString("好", comment: "Dismiss"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func openInitialTerminal() async {
        guard job == nil else { return }
        let active = await LocalLinuxJobScheduler.shared.activeJobs()
        terminalJobs = visibleTerminalJobs(in: active)
        if let initialJobID, let selected = active.first(where: { $0.id == initialJobID }) {
            attach(to: selected)
            await sendStartupInputIfNeeded(to: selected)
            return
        }
        for terminal in terminalJobs where terminal.runID == nil {
            if (try? await LocalLinuxJobScheduler.shared.terminalInputOwner(jobID: terminal.id)) == .user {
                attach(to: terminal)
                return
            }
        }
        await createTerminal()
    }

    private func createTerminal() async {
        do {
            let workspace = try await LocalLinuxStorageManager.shared.interactiveUserWorkspace()
            let started = try await LocalLinuxJobScheduler.shared.startTerminal(
                context: nil,
                workspace: workspace,
                inputOwner: .user,
                columns: 80,
                rows: 24
            )
            terminalJobs.insert(started, at: 0)
            attach(to: started)
            await sendStartupInputIfNeeded(to: started)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func attach(to selected: LocalLinuxJob) {
        let appearance = terminalAppearance
        job = selected
        output = .empty
        outputTask?.cancel()
        outputTask = Task {
            inputOwner = try? await LocalLinuxJobScheduler.shared.terminalInputOwner(jobID: selected.id)
            while !Task.isCancelled {
                if let presentation = try? await LocalLinuxJobScheduler.shared.userVisibleTerminalPresentation(
                    jobID: selected.id,
                    appearance: appearance
                ) {
                    output = presentation
                }
                if let current = await LocalLinuxJobScheduler.shared.job(id: selected.id) {
                    job = current
                    if current.state.isTerminal { break }
                } else {
                    break
                }
                try? await Task<Never, Never>.sleep(nanoseconds: 250_000_000)
            }
            terminalJobs = visibleTerminalJobs(in: await LocalLinuxJobScheduler.shared.activeJobs())
        }
    }

    private func visibleTerminalJobs(in jobs: [LocalLinuxJob]) -> [LocalLinuxJob] {
        jobs.filter { terminal in
            guard terminal.kind == .terminal, !terminal.state.isTerminal else { return false }
            let isStandaloneUserTerminal = terminal.sessionID == nil && terminal.runID == nil
            return isStandaloneUserTerminal || terminal.id == initialJobID
        }
    }

    private func sendRaw(_ data: Data) {
        guard let job, !job.state.isTerminal, !data.isEmpty else { return }
        Task {
            do {
                if inputOwner != .user {
                    try await LocalLinuxJobScheduler.shared.claimTerminalInput(jobID: job.id, owner: .user)
                    inputOwner = .user
                }
                try await LocalLinuxJobScheduler.shared.sendTerminalInput(
                    jobID: job.id,
                    owner: .user,
                    data: data
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func terminalKey(_ shortcut: LocalLinuxTerminalShortcut) -> some View {
        Button(shortcut.title) { sendRaw(shortcut.inputData) }
            .buttonStyle(.bordered)
            .disabled(!isTerminalActive)
    }

    @ViewBuilder
    private var installationStatusBar: some View {
        if startupInput != nil, let job {
            HStack {
                if isTerminalActive {
                    ProgressView()
                    Text(NSLocalizedString("正在安装", comment: "Linux recipe installing status"))
                } else {
                    Label(
                        job.state.displayName,
                        systemImage: job.state == .completed
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(job.state == .completed ? .green : .red)
                }

                Spacer()

                if isTerminalActive {
                    Text(job.startedAt ?? job.createdAt, style: .timer)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button(action: interruptForegroundProgram) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("中断前台程序", comment: "Interrupt terminal"))
                }
            }
            .font(.caption)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func interruptForegroundProgram() {
        guard let job else { return }
        Task { try? await LocalLinuxJobScheduler.shared.interrupt(jobID: job.id) }
    }

    private func resize(for size: CGSize) {
        guard let job else { return }
        let columns = UInt16(min(Int(UInt16.max), max(20, Int(size.width / 8))))
        let rows = UInt16(min(Int(UInt16.max), max(5, Int(size.height / 19))))
        Task { try? await LocalLinuxJobScheduler.shared.resizeTerminal(jobID: job.id, columns: columns, rows: rows) }
    }

    private func returnInputToAgent() {
        guard let job, let runID = job.runID else { return }
        Task {
            do {
                let owner = LocalLinuxTerminalInputOwner.agent(runID: runID)
                try await LocalLinuxJobScheduler.shared.claimTerminalInput(jobID: job.id, owner: owner)
                inputOwner = owner
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private var isInputControlledByAgent: Bool {
        guard let inputOwner else { return false }
        if case .agent = inputOwner { return true }
        return false
    }

    private var terminalAppearance: LocalLinuxTerminalAppearance {
        colorScheme == .dark ? .dark : .light
    }

    private var terminalCanvasColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var isTerminalActive: Bool {
        guard let job else { return false }
        return !job.state.isTerminal
    }

    private func reloadTerminalShortcuts() {
        terminalShortcuts = LocalLinuxTerminalShortcutConfiguration.decode(appConfig.localLinuxTerminalShortcutIDs)
    }

    private func terminalLabel(_ terminal: LocalLinuxJob) -> String {
        String(
            format: NSLocalizedString("终端 %@", comment: "Linux terminal short label"),
            String(terminal.id.uuidString.prefix(8))
        )
    }

    private func sendInput() {
        guard !input.isEmpty else { return }
        let text = input + "\n"
        input = ""
        sendRaw(Data(text.utf8))
    }

    private func sendStartupInputIfNeeded(to terminal: LocalLinuxJob) async {
        guard !didSendStartupInput, let startupInput else { return }
        didSendStartupInput = true
        do {
            try await LocalLinuxJobScheduler.shared.sendTerminalInput(
                jobID: terminal.id,
                owner: .user,
                data: startupInput
            )
        } catch {
            didSendStartupInput = false
            errorMessage = error.localizedDescription
        }
    }
}

struct LocalLinuxJobsView: View {
    private struct JobGroup: Identifiable, Sendable {
        let sessionID: UUID?
        let runID: UUID?
        let jobs: [LocalLinuxJob]
        var id: String { "\(sessionID?.uuidString ?? "device")/\(runID?.uuidString ?? "user")" }
    }

    let sessionID: UUID?
    @State private var groups: [JobGroup] = []
    @State private var activeJobs: [LocalLinuxJob] = []
    @State private var historyJobs: [LocalLinuxJob] = []
    @State private var nextHistoryCursor: LocalLinuxJobCursor?
    @State private var isLoadingHistory = false

    var body: some View {
        List {
            if groups.isEmpty {
                Text(NSLocalizedString("还没有本地 Agent 任务。", comment: "No local Agent jobs"))
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.jobs) { job in
                        NavigationLink {
                            if job.kind == .terminal, !job.state.isTerminal {
                                LocalLinuxTerminalView(initialJobID: job.id)
                            } else {
                                LocalLinuxJobDetailView(jobID: job.id)
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(job.request.executable).font(.body.monospaced())
                                    Spacer()
                                    Text(job.state.displayName).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(job.kind.displayName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            if !job.state.isTerminal {
                                Button(NSLocalizedString("取消", comment: "Cancel"), role: .destructive) {
                                    Task { await LocalLinuxJobScheduler.shared.cancel(jobID: job.id) }
                                }
                            }
                        }
                    }
                    if let runID = group.runID,
                       group.jobs.contains(where: { !$0.state.isTerminal }) {
                        Button(NSLocalizedString("停止此 Agent", comment: "Stop this Linux Agent run"), role: .destructive) {
                            Task { await ChatService.shared.stopConversationRun(runID) }
                        }
                    }
                } header: {
                    Text(groupTitle(group))
                }
            }

            if groups.contains(where: { $0.jobs.contains(where: { !$0.state.isTerminal }) }) {
                Section(NSLocalizedString("停止范围", comment: "Linux task cancellation scopes")) {
                    if let sessionID {
                        Button(NSLocalizedString("停止此会话的全部任务", comment: "Stop all Linux tasks in session"), role: .destructive) {
                            Task { await LocalLinuxJobScheduler.shared.cancel(sessionID: sessionID) }
                        }
                    }
                    Button(NSLocalizedString("停止全部本地任务", comment: "Stop all local Agent tasks"), role: .destructive) {
                        Task { await LocalLinuxJobScheduler.shared.cancelAll() }
                    }
                }
            }

            if nextHistoryCursor != nil {
                Section {
                    Button(NSLocalizedString("加载更多历史任务", comment: "Load more Linux job history")) {
                        Task { await loadMoreHistory() }
                    }
                    .disabled(isLoadingHistory)
                } footer: {
                    Text(NSLocalizedString("活跃任务始终完整显示；已结束任务按需加载。", comment: "Linux jobs history pagination footer"))
                }
            }
        }
        .navigationTitle(NSLocalizedString("任务与终端", comment: "Linux jobs title"))
        .task {
            await loadInitialPage()
            while !Task.isCancelled {
                await reloadActiveJobs()
                try? await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func loadInitialPage() async {
        isLoadingHistory = true
        let page = await LocalLinuxJobScheduler.shared.jobsPage(
            sessionID: sessionID,
            historyLimit: 50
        )
        activeJobs = page.activeJobs
        historyJobs = page.historyJobs
        nextHistoryCursor = page.nextCursor
        isLoadingHistory = false
        await rebuildGroups()
    }

    private func loadMoreHistory() async {
        guard let cursor = nextHistoryCursor, !isLoadingHistory else { return }
        isLoadingHistory = true
        let page = await LocalLinuxJobScheduler.shared.jobsPage(
            sessionID: sessionID,
            cursor: cursor,
            historyLimit: 50
        )
        let knownIDs = Set(historyJobs.map(\.id))
        historyJobs.append(contentsOf: page.historyJobs.filter { !knownIDs.contains($0.id) })
        nextHistoryCursor = page.nextCursor
        isLoadingHistory = false
        await rebuildGroups()
    }

    private func reloadActiveJobs() async {
        let previousIDs = Set(activeJobs.map(\.id))
        let current = (await LocalLinuxJobScheduler.shared.activeJobs())
            .filter { sessionID == nil || $0.sessionID == sessionID }
        let currentIDs = Set(current.map(\.id))
        for id in previousIDs.subtracting(currentIDs) {
            if let finished = await LocalLinuxJobScheduler.shared.job(id: id), finished.state.isTerminal {
                historyJobs.removeAll { $0.id == id }
                historyJobs.append(finished)
            }
        }
        activeJobs = current
        await rebuildGroups()
    }

    private func rebuildGroups() async {
        let activeIDs = Set(activeJobs.map(\.id))
        let jobs = activeJobs + historyJobs.filter { !activeIDs.contains($0.id) }
        groups = await Task.detached(priority: .utility) {
            LocalLinuxJobScheduler.orderedJobGroups(jobs).map { values in
                JobGroup(
                    sessionID: values.first?.sessionID,
                    runID: values.first?.runID,
                    jobs: values
                )
            }
        }.value
    }

    private func groupTitle(_ group: JobGroup) -> String {
        let sessionPrefix: String
        if sessionID == nil, let groupSessionID = group.sessionID {
            sessionPrefix = String(
                format: NSLocalizedString("会话 %@ · ", comment: "Linux task session group prefix"),
                String(groupSessionID.uuidString.prefix(8))
            )
        } else {
            sessionPrefix = ""
        }
        if let runID = group.runID {
            return sessionPrefix + String(
                format: NSLocalizedString("Agent %@", comment: "Linux Agent run group title"),
                String(runID.uuidString.prefix(8))
            )
        }
        return sessionPrefix + NSLocalizedString("用户与长期进程", comment: "User and long-running Linux jobs group")
    }
}

private struct LocalLinuxJobDetailView: View {
    let jobID: UUID
    @State private var job: LocalLinuxJob?
    @State private var outputPage = LocalLinuxRawOutputPage(
        cursor: LocalLinuxRawOutputCursor(),
        text: "",
        nextCursor: nil,
        isComplete: true
    )
    @State private var cursorHistory: [LocalLinuxRawOutputCursor] = []

    var body: some View {
        Form {
            if let job {
                Section(NSLocalizedString("状态", comment: "Linux job status section")) {
                    LabeledContent(NSLocalizedString("任务", comment: "Linux job ID"), value: job.id.uuidString)
                    LabeledContent(NSLocalizedString("类型", comment: "Linux job kind"), value: job.kind.displayName)
                    LabeledContent(NSLocalizedString("状态", comment: "Status"), value: job.state.displayName)
                    LabeledContent(NSLocalizedString("工作目录", comment: "Linux working directory"), value: job.request.workingDirectory ?? "/")
                    if let sessionID = job.sessionID {
                        LabeledContent(NSLocalizedString("会话", comment: "Linux job session"), value: sessionID.uuidString)
                    }
                    if let runID = job.runID {
                        LabeledContent(NSLocalizedString("Agent Run", comment: "Linux job Agent run"), value: runID.uuidString)
                    }
                    if let toolCallID = job.toolCallID {
                        LabeledContent(NSLocalizedString("工具调用", comment: "Linux job tool call"), value: toolCallID)
                    }
                    if let completionReason = job.completionReason {
                        LabeledContent(NSLocalizedString("完成原因", comment: "Linux job completion reason"), value: completionReason.displayName)
                    }
                    if let exitCode = job.exitCode {
                        LabeledContent(NSLocalizedString("退出码", comment: "Linux exit code"), value: "\(exitCode)")
                    }
                    if let diagnosticID = job.diagnosticID {
                        LabeledContent(NSLocalizedString("诊断编号", comment: "Linux diagnostic ID"), value: diagnosticID.uuidString)
                    }
                    if let match = job.request.commandRuleMatch {
                        LabeledContent(NSLocalizedString("规则", comment: "Linux matched command rule"), value: match.ruleName)
                        LabeledContent(NSLocalizedString("匹配内容", comment: "Linux matched command text"), value: match.matchedText)
                        LabeledContent(NSLocalizedString("处理", comment: "Linux command rule action"), value: match.action.displayName)
                    }
                    LabeledContent(NSLocalizedString("stdout", comment: "Linux stdout bytes"), value: ByteCountFormatter.string(fromByteCount: Int64(clamping: job.stdoutBytes), countStyle: .file))
                    LabeledContent(NSLocalizedString("stderr", comment: "Linux stderr bytes"), value: ByteCountFormatter.string(fromByteCount: Int64(clamping: job.stderrBytes), countStyle: .file))
                }
                Section(NSLocalizedString("原始输出", comment: "Linux raw output section")) {
                    Text(outputPage.text.isEmpty ? NSLocalizedString("没有输出。", comment: "No Linux output") : outputPage.text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    HStack {
                        Button(NSLocalizedString("上一页", comment: "Previous Linux output page")) {
                            guard let previous = cursorHistory.popLast() else { return }
                            Task { await loadPage(cursor: previous) }
                        }
                        .disabled(cursorHistory.isEmpty)
                        Spacer()
                        Text(
                            String(
                                format: NSLocalizedString("第 %lld 页", comment: "Linux output page number"),
                                Int64(cursorHistory.count + 1)
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button(NSLocalizedString("下一页", comment: "Next Linux output page")) {
                            guard let next = outputPage.nextCursor else { return }
                            cursorHistory.append(outputPage.cursor)
                            Task { await loadPage(cursor: next) }
                        }
                        .disabled(outputPage.nextCursor == nil)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(NSLocalizedString("任务详情", comment: "Linux job detail title"))
        .task {
            while !Task.isCancelled {
                await reload()
                if job?.state.isTerminal == true { break }
                try? await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func reload() async {
        job = await LocalLinuxJobScheduler.shared.job(id: jobID)
        await loadPage(cursor: outputPage.cursor)
    }

    private func loadPage(cursor: LocalLinuxRawOutputCursor) async {
        if let page = try? await LocalLinuxJobScheduler.shared.userVisibleOutputPage(
            jobID: jobID,
            cursor: cursor,
            maximumBytes: 65_536
        ) {
            outputPage = page
        }
    }
}

struct LocalLinuxRecipesView: View {
    private struct InstallationTerminalTarget: Identifiable, Hashable {
        let recipe: LocalLinuxEnvironmentRecipe
        let jobID: UUID

        var id: UUID { jobID }
    }

    private enum RecipeStatus {
        case running
        case installed
        case failed
    }

    @State private var selectedRecipe: LocalLinuxEnvironmentRecipe?
    @State private var recipeStatuses: [String: RecipeStatus] = [:]
    @State private var activeRecipe: LocalLinuxEnvironmentRecipe?
    @State private var result: LocalLinuxEnvironmentInstallationResult?
    @State private var errorMessage: String?
    @State private var installationTerminalTarget: InstallationTerminalTarget?

    var body: some View {
        List {
            Section {
                ForEach(LocalLinuxEnvironmentRecipes.all) { recipe in
                    Button {
                        selectedRecipe = recipe
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(recipe.title).foregroundStyle(.primary)
                                Text(recipe.detail).font(.caption).foregroundStyle(.secondary)
                                Text(recipe.command).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            statusView(for: recipe)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(activeRecipe != nil)
                }
            } footer: {
                Text(NSLocalizedString("ETOS 默认不安装任何开发环境。点击后会先展示准确命令，由你确认后执行。", comment: "Linux recipes footer"))
            }
            installationResultSection
        }
        .navigationTitle(NSLocalizedString("安装常用环境", comment: "Linux recipes title"))
        .navigationDestination(item: $installationTerminalTarget) { target in
            LocalLinuxTerminalView(
                initialJobID: target.jobID,
                startupInput: target.recipe.terminalInput,
                title: target.recipe.title
            )
        }
        .confirmationDialog(
            selectedRecipe?.title ?? "",
            isPresented: Binding(get: { selectedRecipe != nil }, set: { if !$0 { selectedRecipe = nil } }),
            titleVisibility: .visible
        ) {
            if let recipe = selectedRecipe {
                Button(NSLocalizedString("复制命令", comment: "Copy Linux recipe command")) {
                    UIPasteboard.general.string = recipe.command
                }
                Button(NSLocalizedString("执行此命令", comment: "Execute Linux recipe command")) {
                    run(recipe)
                }
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(selectedRecipe?.confirmationDetail ?? "")
        }
    }

    private func run(_ recipe: LocalLinuxEnvironmentRecipe) {
        selectedRecipe = nil
        activeRecipe = recipe
        result = nil
        errorMessage = nil
        recipeStatuses[recipe.id] = .running
        Task {
            do {
                let terminal = try await LocalLinuxEnvironmentInstaller.startTerminal(columns: 80, rows: 24)
                installationTerminalTarget = InstallationTerminalTarget(recipe: recipe, jobID: terminal.id)
                let installation = try await LocalLinuxEnvironmentInstaller.waitForCompletion(jobID: terminal.id)
                result = installation
                recipeStatuses[recipe.id] = installation.succeeded ? .installed : .failed
            } catch {
                errorMessage = error.localizedDescription
                recipeStatuses[recipe.id] = .failed
            }
            activeRecipe = nil
        }
    }

    @ViewBuilder
    private func statusView(for recipe: LocalLinuxEnvironmentRecipe) -> some View {
        switch recipeStatuses[recipe.id] {
        case .running:
            ProgressView()
        case .installed:
            Label(NSLocalizedString("已安装", comment: "Linux recipe installed status"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .failed:
            Label(NSLocalizedString("失败", comment: "Linux recipe failed status"), systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .labelStyle(.titleAndIcon)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var installationResultSection: some View {
        if let activeRecipe {
            Section(activeRecipe.title) {
                HStack {
                    ProgressView()
                    Text(NSLocalizedString("正在安装", comment: "Linux recipe installing status"))
                }
                Text(activeRecipe.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        } else if let result {
            Section(NSLocalizedString("最近结果", comment: "Linux recipe result")) {
                Label(
                    result.succeeded
                        ? NSLocalizedString("已安装", comment: "Linux recipe installed status")
                        : NSLocalizedString("失败", comment: "Linux recipe failed status"),
                    systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .foregroundStyle(result.succeeded ? .green : .red)
                if let exitCode = result.job.exitCode {
                    LabeledContent(NSLocalizedString("退出码", comment: "Linux recipe exit code"), value: "\(exitCode)")
                }
                Text(
                    result.output.isEmpty
                        ? (result.succeeded
                            ? NSLocalizedString("命令已成功执行。", comment: "Linux recipe succeeded without output")
                            : result.job.state.displayName)
                        : result.output
                )
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }
        } else if let errorMessage {
            Section(NSLocalizedString("最近结果", comment: "Linux recipe result")) {
                Label(NSLocalizedString("失败", comment: "Linux recipe failed status"), systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text(errorMessage)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}

struct LocalLinuxFileBrowserView: View {
    @State private var path = "/"
    @State private var entries: [LocalLinuxGuestFileInfo] = []
    @State private var selectedFilePath: String?
    @State private var selectedFileContent = ""
    @State private var selectedFileMode: UInt32 = 0o644
    @State private var selectedFileIsEditable = false
    @State private var pendingDelete: (path: String, isDirectory: Bool)?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var nextCursor: UInt64 = 0
    @State private var isDirectoryComplete = true

    var body: some View {
        List {
            Section {
                Text(path).font(.caption.monospaced()).textSelection(.enabled)
                if path != "/" {
                    Button {
                        path = parentPath(path)
                        Task { await reload() }
                    } label: {
                        Label(NSLocalizedString("上一级", comment: "Linux file browser parent"), systemImage: "arrow.up")
                    }
                }
                Button(NSLocalizedString("删除当前目录…", comment: "Delete current Linux directory"), role: .destructive) {
                    pendingDelete = (path, true)
                }
            }

            Section {
                if isLoading { ProgressView() }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    let name = entry.name ?? "?"
                    Button {
                        open(entry)
                    } label: {
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                            VStack(alignment: .leading) {
                                Text(name).foregroundStyle(.primary)
                                if !entry.isDirectory {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                            pendingDelete = (childPath(path, name), entry.isDirectory)
                        }
                    }
                }
                if !isDirectoryComplete {
                    Button(NSLocalizedString("加载更多", comment: "Load more Linux directory entries")) {
                        Task { await loadDirectory(reset: false) }
                    }
                    .disabled(isLoading)
                }
            }
        }
        .navigationTitle(NSLocalizedString("Linux 文件", comment: "Linux files title"))
        .toolbar { Button(NSLocalizedString("刷新", comment: "Refresh")) { Task { await reload() } } }
        .task { await reload() }
        .sheet(isPresented: Binding(get: { selectedFilePath != nil }, set: { if !$0 { selectedFilePath = nil } })) {
            NavigationStack {
                Group {
                    if selectedFileIsEditable {
                        TextEditor(text: $selectedFileContent)
                            .font(.body.monospaced())
                            .padding()
                    } else {
                        ScrollView {
                            Text(selectedFileContent)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                    }
                }
                .navigationTitle(URL(fileURLWithPath: selectedFilePath ?? "").lastPathComponent)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(NSLocalizedString("关闭", comment: "Close")) { selectedFilePath = nil }
                    }
                    if selectedFileIsEditable {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(NSLocalizedString("保存", comment: "Save"), action: saveSelectedFile)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            NSLocalizedString("删除 Linux 路径？", comment: "Delete Linux path confirmation"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) { deletePending() }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("删除系统文件可能让 Linux 无法启动。此操作不会被硬拦截；需要时可回到设置重置系统。", comment: "Delete Linux file warning"))
        }
        .alert(NSLocalizedString("文件操作失败", comment: "Linux file operation failed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(NSLocalizedString("好", comment: "Dismiss"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func reload() async {
        await loadDirectory(reset: true)
    }

    private func loadDirectory(reset: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await LocalLinuxRuntimeController.shared.ensureReady(trigger: .guestFileBrowser)
            let page = try await iSHAppleBridgeAdapter.shared.listGuestDirectory(
                path: path,
                requestID: requestID(),
                cursor: reset ? 0 : nextCursor,
                maximumEntryCount: 512
            )
            let loaded = page.entries.filter { $0.name != "." && $0.name != ".." }
            entries = reset ? loaded : entries + loaded
            nextCursor = page.nextCursor
            isDirectoryComplete = page.isComplete
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ entry: LocalLinuxGuestFileInfo) {
        let target = childPath(path, entry.name ?? "")
        if entry.isDirectory {
            path = target
            Task { await reload() }
            return
        }
        Task {
            do {
                let result = try await iSHAppleBridgeAdapter.shared.readGuestFile(
                    path: target,
                    requestID: requestID(),
                    offset: 0,
                    maximumByteCount: 262_144
                )
                selectedFilePath = target
                selectedFileMode = entry.mode & 0o777
                selectedFileIsEditable = result.isComplete && !result.data.contains(0)
                selectedFileContent = String(decoding: result.data, as: UTF8.self)
                if !result.isComplete {
                    selectedFileContent.append(NSLocalizedString("\n\n[文件较大，仅显示前 256 KiB；为避免覆盖未显示内容，当前预览不可编辑。]", comment: "Large Linux file preview notice"))
                } else if result.data.contains(0) {
                    selectedFileContent = String(
                        format: NSLocalizedString("二进制文件，大小 %@。", comment: "Linux binary file preview"),
                        ByteCountFormatter.string(fromByteCount: Int64(clamping: result.totalSize), countStyle: .file)
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deletePending() {
        guard let pendingDelete else { return }
        self.pendingDelete = nil
        Task {
            do {
                try await iSHAppleBridgeAdapter.shared.removeGuestFile(
                    path: pendingDelete.path,
                    requestID: requestID(),
                    recursive: pendingDelete.isDirectory
                )
                if isCriticalSystemPath(pendingDelete.path) {
                    try await LocalLinuxRuntimeController.shared.markSystemDamaged(
                        reason: NSLocalizedString("用户删除了关键 Linux 系统路径。重新启动本地 Linux 后会从内置系统恢复。", comment: "Critical Linux system path deleted")
                    )
                }
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func childPath(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    private func parentPath(_ path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private func saveSelectedFile() {
        guard let selectedFilePath, selectedFileIsEditable else { return }
        let content = selectedFileContent
        let mode = selectedFileMode
        Task {
            do {
                try await iSHAppleBridgeAdapter.shared.writeGuestFile(
                    path: selectedFilePath,
                    requestID: requestID(),
                    data: Data(content.utf8),
                    mode: mode
                )
                self.selectedFilePath = nil
                await reload()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func isCriticalSystemPath(_ path: String) -> Bool {
        let critical = ["/", "/bin", "/etc", "/lib", "/sbin", "/usr"]
        return critical.contains(path)
    }

    private func requestID() -> UInt64 {
        max(1, UInt64(Date().timeIntervalSince1970 * 1_000_000))
    }
}
