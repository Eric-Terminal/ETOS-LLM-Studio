// watchOS 本地 Linux 的紧凑设置、终端与文件入口。
import ETOSCore
import SwiftUI
struct LocalLinuxWatchFeatureView: View {
    let sessionID: UUID?
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var snapshot = LocalLinuxRuntimeSnapshot(phase: .disabled)
    @State private var errorMessage: String?
    @State private var showResetConfirmation = false
    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("启用本地 Linux", comment: "Watch enable local Linux"), isOn: $appConfig.localLinuxEnabled)
            } footer: {
                Text(NSLocalizedString("开启不会启动系统；终端、文件、recipe、MCP 或 Agent 首次使用时才准备。", comment: "Watch Linux lazy start footer"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Section(NSLocalizedString("状态", comment: "Watch Linux status")) {
                LabeledContent(NSLocalizedString("运行时", comment: "Watch Linux runtime"), value: snapshot.phase.displayName)
                if let progress = snapshot.installProgress,
                   let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                }
                Button(NSLocalizedString("准备系统", comment: "Watch prepare Linux")) {
                    Task {
                        do {
                            snapshot = try await LocalLinuxRuntimeController.shared.ensureReady(trigger: .recipe)
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
                .disabled(!appConfig.localLinuxEnabled || snapshot.phase == .installing || snapshot.phase == .starting)
            }
            LocalLinuxWatchResourceStatusView()
            Section(NSLocalizedString("使用", comment: "Watch Linux use section")) {
                NavigationLink {
                    LocalLinuxWatchTerminalView()
                } label: {
                    Label(NSLocalizedString("用户终端", comment: "Watch Linux terminal entry"), systemImage: "terminal")
                }
                .disabled(!appConfig.localLinuxEnabled)

                NavigationLink {
                    LocalLinuxWatchFileBrowserView()
                } label: {
                    Label(NSLocalizedString("Linux 文件", comment: "Watch Linux files entry"), systemImage: "folder")
                }
                .disabled(!appConfig.localLinuxEnabled)

                NavigationLink {
                    LocalLinuxWatchJobsView(sessionID: sessionID)
                } label: {
                    Label(NSLocalizedString("任务", comment: "Watch Linux jobs entry"), systemImage: "list.bullet.rectangle")
                }

                NavigationLink {
                    LocalLinuxWatchRecipesView()
                } label: {
                    Label(NSLocalizedString("安装常用环境", comment: "Watch Linux recipes entry"), systemImage: "shippingbox")
                }
                .disabled(!appConfig.localLinuxEnabled)
            }

            Section {
                NavigationLink(NSLocalizedString("环境变量", comment: "Watch Linux environment entry")) {
                    LocalLinuxWatchEnvironmentView()
                }
                NavigationLink(NSLocalizedString("Agent 提示词", comment: "Watch Agent prompt entry")) {
                    LocalLinuxWatchPromptView()
                }
                NavigationLink(NSLocalizedString("安全策略", comment: "Watch Linux safety entry")) {
                    LocalLinuxWatchSafetyView()
                }
                NavigationLink(NSLocalizedString("挂载目录", comment: "Watch Linux mounts entry")) {
                    LocalLinuxWatchMountsView()
                }
                NavigationLink(NSLocalizedString("MCP 服务器", comment: "Watch local Linux MCP management entry")) {
                    MCPIntegrationView()
                }
                NavigationLink(NSLocalizedString("许可与源码", comment: "Watch Linux compliance entry")) { LocalLinuxComplianceWatchView() }
                TextField(
                    NSLocalizedString("默认超时（秒，0 表示不限）", comment: "Watch default Linux timeout"),
                    value: defaultTimeoutBinding,
                    formatter: Self.integerFormatter
                )
                TextField(
                    NSLocalizedString("模型输出预览（字节）", comment: "Watch Linux model output preview bytes"),
                    value: outputPreviewBinding,
                    formatter: Self.integerFormatter
                )
            } header: {
                Text(NSLocalizedString("配置", comment: "Watch Linux configuration section"))
            } footer: {
                Text(NSLocalizedString("0 秒表示不限时；预览只影响发送给模型的副本。", comment: "Watch Linux execution defaults footer"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    NSLocalizedString("发送给模型前隐藏环境变量值", comment: "Watch Linux output privacy toggle"),
                    isOn: $appConfig.localLinuxEnvironmentPrivacyEnabled
                )
            } footer: {
                Text(NSLocalizedString("开启后，命令与本地 MCP 输出中出现已启用环境变量的值时，只会在发送给模型前替换；用户终端和原始日志保持不变。关闭后会原样发送。", comment: "Watch Linux model copy redaction footer"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(NSLocalizedString("重置系统…", comment: "Watch reset Linux"), role: .destructive) {
                    showResetConfirmation = true
                }
            } footer: {
                Text(NSLocalizedString("只重建 System，保留 Home、Shared 与工作区。删除或改坏系统文件由用户自行承担；重置可以恢复。", comment: "Watch reset Linux footer"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("本地 Linux", comment: "Watch local Linux title"))
        .task {
            snapshot = await LocalLinuxRuntimeController.shared.refreshInstalledState()
            for await update in await LocalLinuxRuntimeController.shared.updates() {
                if Task.isCancelled { break }
                snapshot = update
            }
        }
        .confirmationDialog(
            NSLocalizedString("重置本地 Linux？", comment: "Watch reset Linux confirmation"),
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("重置系统", comment: "Watch reset Linux action"), role: .destructive) {
                Task {
                    do { try await LocalLinuxRuntimeController.shared.deleteSystem(deleteUserData: false) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        }
        .alert(NSLocalizedString("操作失败", comment: "Watch Linux operation failed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(NSLocalizedString("好", comment: "Dismiss"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private var defaultTimeoutBinding: Binding<Int> {
        Binding(
            get: { appConfig.localLinuxDefaultTimeoutSeconds },
            set: { appConfig.localLinuxDefaultTimeoutSeconds = min(max(0, $0), 4_294_967) }
        )
    }

    private var outputPreviewBinding: Binding<Int> {
        Binding(
            get: { appConfig.localLinuxOutputPreviewBytes },
            set: { appConfig.localLinuxOutputPreviewBytes = max(4_096, $0) }
        )
    }
}

struct LocalLinuxWatchTerminalView: View {
    let initialJobID: UUID?
    @State private var job: LocalLinuxJob?
    @State private var terminalJobs: [LocalLinuxJob] = []
    @State private var inputOwner: LocalLinuxTerminalInputOwner?
    @State private var output = ""
    @State private var input = ""
    @State private var errorMessage: String?
    @State private var outputTask: Task<Void, Never>?

    init(initialJobID: UUID? = nil) {
        self.initialJobID = initialJobID
    }

    var body: some View {
        List {
            Section {
                Text(output.isEmpty ? NSLocalizedString("正在启动…", comment: "Watch Linux terminal starting") : output)
                    .font(.caption2.monospaced())
                if let inputOwner {
                    Text(inputOwnerLabel(inputOwner))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                TextField(NSLocalizedString("输入", comment: "Watch Linux terminal input"), text: $input)
                    .onSubmit(send)
                Button(NSLocalizedString("发送", comment: "Send"), action: send)
                    .disabled(job == nil || input.isEmpty)
                Button(NSLocalizedString("中断", comment: "Interrupt")) {
                    guard let job else { return }
                    Task { try? await LocalLinuxJobScheduler.shared.interrupt(jobID: job.id) }
                }
                Button(NSLocalizedString("结束", comment: "Stop"), role: .destructive) {
                    guard let job else { return }
                    Task { await LocalLinuxJobScheduler.shared.cancel(jobID: job.id) }
                }
            }
            Section(NSLocalizedString("终端", comment: "Watch terminal sessions section")) {
                Button(NSLocalizedString("新建终端", comment: "Watch create Linux terminal")) {
                    Task { await createTerminal() }
                }
                ForEach(terminalJobs) { terminal in
                    Button(terminalLabel(terminal)) { attach(to: terminal) }
                }
                if inputOwner == .user, job?.runID != nil {
                    Button(NSLocalizedString("将输入交还 Agent", comment: "Watch return terminal input to Agent"), action: returnInputToAgent)
                }
            }
        }
        .navigationTitle(NSLocalizedString("终端", comment: "Watch Linux terminal title"))
        .task { await openInitialTerminal() }
        .onDisappear { outputTask?.cancel() }
        .alert(NSLocalizedString("终端错误", comment: "Watch Linux terminal error"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(NSLocalizedString("好", comment: "Dismiss"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func openInitialTerminal() async {
        guard job == nil else { return }
        let active = await LocalLinuxJobScheduler.shared.activeJobs()
        terminalJobs = visibleTerminalJobs(in: active)
        if let initialJobID, let selected = active.first(where: { $0.id == initialJobID }) {
            attach(to: selected)
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
                columns: 40,
                rows: 12
            )
            terminalJobs.insert(started, at: 0)
            attach(to: started)
        } catch { errorMessage = error.localizedDescription }
    }

    private func attach(to selected: LocalLinuxJob) {
        job = selected
        output = ""
        outputTask?.cancel()
        outputTask = Task {
            inputOwner = try? await LocalLinuxJobScheduler.shared.terminalInputOwner(jobID: selected.id)
            while !Task.isCancelled {
                output = (try? await LocalLinuxJobScheduler.shared.userVisibleOutput(jobID: selected.id)) ?? output
                let current = await LocalLinuxJobScheduler.shared.job(id: selected.id)
                job = current
                if current?.state.isTerminal == true { break }
                try? await Task<Never, Never>.sleep(nanoseconds: 500_000_000)
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

    private func send() {
        guard let job, !input.isEmpty else { return }
        let text = input + "\n"
        input = ""
        Task {
            do {
                if inputOwner != .user {
                    try await LocalLinuxJobScheduler.shared.claimTerminalInput(jobID: job.id, owner: .user)
                    inputOwner = .user
                }
                try await LocalLinuxJobScheduler.shared.sendTerminalInput(jobID: job.id, owner: .user, data: Data(text.utf8))
            } catch { errorMessage = error.localizedDescription }
        }
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

    private func inputOwnerLabel(_ owner: LocalLinuxTerminalInputOwner) -> String {
        switch owner {
        case .user: return NSLocalizedString("输入由你控制", comment: "Watch terminal user input owner")
        case .agent: return NSLocalizedString("输入由 Agent 控制；发送内容即可接管", comment: "Watch terminal Agent input owner")
        }
    }

    private func terminalLabel(_ terminal: LocalLinuxJob) -> String {
        String(
            format: NSLocalizedString("切换到终端 %@", comment: "Watch switch Linux terminal"),
            String(terminal.id.uuidString.prefix(8))
        )
    }
}

private struct LocalLinuxWatchEnvironmentView: View {
    @State private var variables: [LocalLinuxEnvironmentVariable] = []

    var body: some View {
        List {
            Section {
                NavigationLink(NSLocalizedString("添加变量", comment: "Watch add environment variable")) {
                    LocalLinuxWatchEnvironmentEditorView(variable: nil)
                }
            }
            Section(NSLocalizedString("变量", comment: "Watch Linux environment variables")) {
                if variables.isEmpty {
                    Text(NSLocalizedString("还没有变量。", comment: "Watch no Linux environment variables"))
                        .foregroundStyle(.secondary)
                }
                ForEach(variables) { variable in
                    NavigationLink {
                        LocalLinuxWatchEnvironmentEditorView(variable: variable)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(variable.name).font(.caption.monospaced())
                            Text("••••••••")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            if !variable.isEnabled {
                                Text(NSLocalizedString("已停用", comment: "Watch disabled environment variable"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Text(NSLocalizedString("已启用的变量会自动注入新建的命令、终端与本地 MCP 进程。列表始终隐藏值；点进变量即可查看和编辑。", comment: "Watch Linux environment footer"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(NSLocalizedString("环境变量", comment: "Watch Linux environment title"))
        .task { await reload() }
        .onAppear { Task { await reload() } }
    }

    private func reload() async { variables = await LocalLinuxProcessEnvironmentProvider.shared.variables() }
}

private struct LocalLinuxWatchEnvironmentEditorView: View {
    @Environment(\.dismiss) private var dismiss
    private let isNew: Bool
    @State private var draft: LocalLinuxEnvironmentVariable
    @State private var errorMessage: String?

    init(variable: LocalLinuxEnvironmentVariable?) {
        isNew = variable == nil
        _draft = State(initialValue: variable ?? LocalLinuxEnvironmentVariable(name: "", value: ""))
    }

    var body: some View {
        List {
            TextField(NSLocalizedString("名称", comment: "Environment name"), text: $draft.name)
            TextField(NSLocalizedString("值", comment: "Environment value"), text: $draft.value)
            TextField(NSLocalizedString("备注", comment: "Environment note"), text: $draft.note)
            Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: $draft.isEnabled)
            Button(NSLocalizedString("保存", comment: "Save"), action: save)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !isNew {
                Button(NSLocalizedString("删除变量", comment: "Watch delete environment variable"), role: .destructive) {
                    deleteVariable()
                }
            }
        }
        .navigationTitle(isNew
            ? NSLocalizedString("添加变量", comment: "Watch add environment variable title")
            : draft.name)
        .alert(NSLocalizedString("保存失败", comment: "Save failed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(NSLocalizedString("好", comment: "Dismiss"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.updatedAt = Date()
        Task {
            do {
                try await LocalLinuxProcessEnvironmentProvider.shared.save(draft)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func deleteVariable() {
        Task {
            do {
                try await LocalLinuxProcessEnvironmentProvider.shared.delete(id: draft.id)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct LocalLinuxWatchSafetyView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var rules: [LocalLinuxCommandRule] = []

    var body: some View {
        List {
            Toggle(NSLocalizedString("启用安全策略", comment: "Watch enable Linux safety"), isOn: $appConfig.localLinuxCommandSafetyEnabled)
            NavigationLink(NSLocalizedString("添加规则", comment: "Watch add Linux rule")) {
                LocalLinuxWatchSafetyRuleEditorView(
                    rule:
                        LocalLinuxCommandRule(
                            name: "",
                            pattern: "",
                            matchKind: .prefix,
                            scope: .all,
                            action: .confirm,
                            sortIndex: rules.count
                        )
                )
            }
            Section(NSLocalizedString("规则", comment: "Watch Linux rules")) {
                if rules.isEmpty {
                    Text(NSLocalizedString("还没有规则。", comment: "Watch no Linux safety rules"))
                        .foregroundStyle(.secondary)
                }
                ForEach(rules) { rule in
                    NavigationLink {
                        LocalLinuxWatchSafetyRuleEditorView(rule: rule)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(rule.name)
                            Text(rule.pattern).font(.caption.monospaced())
                            Text("\(rule.action.displayName) · \(rule.scope.displayName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text(NSLocalizedString("关闭后完全放行；不会保留不可关闭的黑名单。", comment: "Watch Linux safety footer"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(NSLocalizedString("安全策略", comment: "Watch Linux safety title"))
        .task { await reload() }
        .onAppear { Task { await reload() } }
    }

    private func reload() async { rules = await LocalLinuxApprovalPolicy.shared.rules() }
}

private struct LocalLinuxWatchSafetyRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LocalLinuxCommandRule
    @State private var validationMessage: String?
    @State private var errorMessage: String?

    init(rule: LocalLinuxCommandRule) {
        _draft = State(initialValue: rule)
    }

    var body: some View {
        List {
            TextField(NSLocalizedString("名称", comment: "Watch Linux rule name"), text: $draft.name)
            TextField(NSLocalizedString("匹配内容", comment: "Watch Linux rule pattern"), text: $draft.pattern)
            if let validationMessage {
                Text(validationMessage).font(.caption2).foregroundStyle(.red)
            }
            Picker(NSLocalizedString("匹配方式", comment: "Watch Linux rule match kind"), selection: $draft.matchKind) {
                ForEach(LocalLinuxCommandRuleMatchKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            Picker(NSLocalizedString("范围", comment: "Watch Linux rule scope"), selection: $draft.scope) {
                ForEach(LocalLinuxCommandRuleScope.allCases, id: \.self) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            Picker(NSLocalizedString("处理", comment: "Watch Linux rule action"), selection: $draft.action) {
                ForEach(LocalLinuxCommandRuleAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }
            Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: $draft.isEnabled)
            Stepper(
                String(
                    format: NSLocalizedString("优先级 %d", comment: "Watch Linux rule priority"),
                    draft.sortIndex + 1
                ),
                value: $draft.sortIndex,
                in: 0...999
            )
            Button(NSLocalizedString("保存", comment: "Save"), action: save)
                .disabled(
                    draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || validationMessage != nil
                )
            Button(NSLocalizedString("删除规则", comment: "Watch delete Linux rule"), role: .destructive) {
                deleteRule()
            }
        }
        .navigationTitle(draft.name.isEmpty
            ? NSLocalizedString("命令规则", comment: "Watch Linux command rule title")
            : draft.name)
        .task { validatePattern() }
        .onChange(of: draft.pattern) { _, _ in validatePattern() }
        .onChange(of: draft.matchKind) { _, _ in validatePattern() }
        .alert(NSLocalizedString("保存失败", comment: "Save failed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(NSLocalizedString("好", comment: "Dismiss"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func validatePattern() {
        let pattern = draft.pattern
        let kind = draft.matchKind
        Task {
            let error = await Task.detached(priority: .utility) { () -> String? in
                guard kind == .regularExpression, !pattern.isEmpty else { return nil }
                do {
                    _ = try NSRegularExpression(pattern: pattern)
                    return nil
                } catch { return error.localizedDescription }
            }.value
            guard draft.pattern == pattern, draft.matchKind == kind else { return }
            validationMessage = error
        }
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.pattern = draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.name.isEmpty { draft.name = draft.pattern }
        draft.updatedAt = Date()
        Task {
            do {
                try await LocalLinuxApprovalPolicy.shared.save(draft)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func deleteRule() {
        Task {
            do {
                try await LocalLinuxApprovalPolicy.shared.delete(id: draft.id)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct LocalLinuxWatchMountsView: View {
    @State private var mounts: [LocalLinuxMountRecord] = []

    var body: some View {
        List {
            NavigationLink(NSLocalizedString("工作区", comment: "Watch Linux workspaces entry")) {
                LocalLinuxWatchWorkspacesView()
            }
            if mounts.isEmpty {
                Text(NSLocalizedString("还没有外部挂载。", comment: "Watch no external Linux mounts"))
                    .foregroundStyle(.secondary)
            }
            ForEach(mounts) { mount in
                NavigationLink {
                    LocalLinuxWatchMountDetailView(record: mount)
                } label: {
                    VStack(alignment: .leading) {
                        Text(mount.displayName)
                        Text(mount.guestPath).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Text("\(mount.access.displayName) · \(mount.authorizationState.displayName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(NSLocalizedString("iCloud 的 Linux 文件固定挂载到 /mnt/icloud。外部目录的系统授权与设备绑定；需要重新授权时请在支持系统文件选择器的设备上重新选择。", comment: "Watch Linux mounts footer"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(NSLocalizedString("挂载目录", comment: "Watch Linux mounts title"))
        .task { await reload() }
        .onAppear { Task { await reload() } }
    }

    private func reload() async {
        mounts = await LocalLinuxMountManager.shared.records()
    }
}

private struct LocalLinuxWatchMountDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var record: LocalLinuxMountRecord
    @State private var errorMessage: String?
    @State private var showRemovalConfirmation = false

    init(record: LocalLinuxMountRecord) {
        _record = State(initialValue: record)
    }

    var body: some View {
        List {
            Text(record.guestPath).font(.caption2.monospaced())
            LabeledContent(NSLocalizedString("权限", comment: "Watch Linux mount access"), value: record.access.displayName)
            LabeledContent(NSLocalizedString("授权", comment: "Watch Linux mount authorization"), value: record.authorizationState.displayName)
            LabeledContent(NSLocalizedString("使用中", comment: "Watch Linux mount active leases"), value: "\(record.activeLeaseCount)")
            Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: enabledBinding)
            Button(NSLocalizedString("移除挂载", comment: "Watch remove Linux mount"), role: .destructive) {
                showRemovalConfirmation = true
            }
        }
        .navigationTitle(record.displayName)
        .confirmationDialog(
            NSLocalizedString("移除此挂载？", comment: "Watch remove Linux mount confirmation"),
            isPresented: $showRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("移除挂载", comment: "Watch remove Linux mount"), role: .destructive) {
                remove(force: false)
            }
            if record.activeLeaseCount > 0 {
                Button(NSLocalizedString("停止相关任务并移除", comment: "Watch force remove Linux mount"), role: .destructive) {
                    remove(force: true)
                }
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("不会删除外部文件。强制移除只会中断正在使用这个挂载的任务。", comment: "Watch remove Linux mount warning"))
        }
        .alert(NSLocalizedString("挂载失败", comment: "Mount failed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(NSLocalizedString("好", comment: "Dismiss"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { record.isEnabled },
            set: { newValue in
                let previous = record.isEnabled
                record.isEnabled = newValue
                Task {
                    do {
                        record = try await LocalLinuxMountManager.shared.setEnabled(newValue, id: record.id)
                    } catch {
                        record.isEnabled = previous
                        errorMessage = error.localizedDescription
                    }
                }
            }
        )
    }

    private func remove(force: Bool) {
        Task {
            do {
                try await LocalLinuxMountManager.shared.delete(id: record.id, force: force)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct LocalLinuxWatchFileBrowserView: View {
    @State private var path = "/"
    @State private var entries: [LocalLinuxGuestFileInfo] = []
    @State private var content = ""
    @State private var selectedFilePath: String?
    @State private var selectedFileMode: UInt32 = 0o644
    @State private var selectedFileIsEditable = false
    @State private var pendingDelete: (path: String, isDirectory: Bool)?
    @State private var nextCursor: UInt64 = 0
    @State private var isDirectoryComplete = true
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Text(path).font(.caption2.monospaced())
            if path != "/" {
                Button(NSLocalizedString("上一级", comment: "Watch Linux parent directory")) {
                    path = URL(fileURLWithPath: path).deletingLastPathComponent().path
                    if path.isEmpty { path = "/" }
                    clearSelection()
                    Task { await reload() }
                }
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                Button {
                    open(entry)
                } label: {
                    Label(entry.name ?? "?", systemImage: entry.isDirectory ? "folder" : "doc")
                }
                .buttonStyle(.plain)
            }
            if !isDirectoryComplete {
                Button(NSLocalizedString("加载更多", comment: "Watch load more Linux files")) {
                    Task { await loadDirectory(reset: false) }
                }
                .disabled(isLoading)
            }
            if let selectedFilePath {
                Text(selectedFilePath).font(.caption2.monospaced())
                if selectedFileIsEditable {
                    TextField(
                        NSLocalizedString("文件内容", comment: "Watch Linux file editor"),
                        text: $content.watchKeyboardNewlineBinding(),
                        axis: .vertical
                    )
                        .font(.caption2.monospaced())
                        .lineLimit(6...16)
                    Button(NSLocalizedString("保存文件", comment: "Watch save Linux file"), action: saveSelectedFile)
                } else {
                    Text(content).font(.caption2.monospaced())
                }
                Button(NSLocalizedString("删除此文件", comment: "Watch delete Linux file"), role: .destructive) {
                    pendingDelete = (selectedFilePath, false)
                }
            }
            Button(NSLocalizedString("删除当前目录…", comment: "Watch delete current Linux directory"), role: .destructive) {
                pendingDelete = (path, true)
            }
            Text(NSLocalizedString("文件读写全部经过 Linux 文件系统。删除系统路径可能让环境损坏；不会硬拦截，需要时可在设置中重置。", comment: "Watch Linux file browser footer"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(NSLocalizedString("Linux 文件", comment: "Watch Linux files title"))
        .task { await reload() }
        .confirmationDialog(
            NSLocalizedString("删除 Linux 路径？", comment: "Watch delete Linux path confirmation"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive, action: deletePending)
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("不会硬拦截系统路径。删除后如无法运行，请重新打开 App 或重置系统。", comment: "Watch delete Linux path warning"))
        }
        .alert(NSLocalizedString("文件错误", comment: "Watch Linux file error"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
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
                maximumEntryCount: 128
            )
            let loaded = page.entries.filter { $0.name != "." && $0.name != ".." }
            entries = reset ? loaded : entries + loaded
            nextCursor = page.nextCursor
            isDirectoryComplete = page.isComplete
        } catch { errorMessage = error.localizedDescription }
    }

    private func open(_ entry: LocalLinuxGuestFileInfo) {
        let target = path == "/" ? "/\(entry.name ?? "")" : "\(path)/\(entry.name ?? "")"
        if entry.isDirectory {
            path = target
            clearSelection()
            Task { await reload() }
        } else {
            Task {
                do {
                    let value = try await iSHAppleBridgeAdapter.shared.readGuestFile(
                        path: target,
                        requestID: requestID(),
                        offset: 0,
                        maximumByteCount: 65_536
                    )
                    selectedFilePath = target
                    selectedFileMode = entry.mode & 0o777
                    selectedFileIsEditable = value.isComplete && !value.data.contains(0)
                    content = String(decoding: value.data, as: UTF8.self)
                    if !value.isComplete {
                        content.append(NSLocalizedString("\n\n[文件较大，仅显示前 64 KiB；当前预览不可编辑。]", comment: "Watch large Linux file preview"))
                    } else if value.data.contains(0) {
                        content = String(
                            format: NSLocalizedString("二进制文件，大小 %@。", comment: "Watch Linux binary file preview"),
                            ByteCountFormatter.string(fromByteCount: Int64(clamping: value.totalSize), countStyle: .file)
                        )
                    }
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func saveSelectedFile() {
        guard let selectedFilePath, selectedFileIsEditable else { return }
        let data = Data(content.utf8)
        let mode = selectedFileMode
        Task {
            do {
                try await iSHAppleBridgeAdapter.shared.writeGuestFile(
                    path: selectedFilePath,
                    requestID: requestID(),
                    data: data,
                    mode: mode
                )
                clearSelection()
                await reload()
            } catch { errorMessage = error.localizedDescription }
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
                        reason: NSLocalizedString("用户删除了关键 Linux 系统路径。重新打开 App 后会从内置系统恢复。", comment: "Watch critical Linux path deleted")
                    )
                    entries = []
                } else {
                    if pendingDelete.path == selectedFilePath { clearSelection() }
                    if pendingDelete.path == path {
                        path = parentPath(path)
                        clearSelection()
                    }
                    await reload()
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func clearSelection() {
        selectedFilePath = nil
        selectedFileIsEditable = false
        content = ""
    }

    private func parentPath(_ value: String) -> String {
        let parent = URL(fileURLWithPath: value).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private func isCriticalSystemPath(_ value: String) -> Bool {
        ["/", "/bin", "/etc", "/lib", "/sbin", "/usr"].contains(value)
    }

    private func requestID() -> UInt64 {
        max(1, UInt64(Date().timeIntervalSince1970 * 1_000_000))
    }
}
