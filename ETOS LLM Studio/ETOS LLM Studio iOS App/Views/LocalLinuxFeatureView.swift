// ============================================================================
// LocalLinuxFeatureView.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 本地 Linux 设置、文件、任务和用户终端入口。总开关本身不启动运行时。
// ============================================================================

import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct LocalLinuxFeatureView: View {
    let sessionID: UUID?

    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var snapshot = LocalLinuxRuntimeSnapshot(phase: .disabled)
    @State private var usage = LocalLinuxStorageUsage(
        systemBytes: 0,
        homeBytes: 0,
        sharedBytes: 0,
        workspaceBytes: 0,
        exportBytes: 0
    )
    @State private var errorMessage: String?
    @State private var deleteUserData = false
    @State private var showResetConfirmation = false
    @State private var isPreparingRuntime = false
    @State private var isResettingSystem = false
    @State private var resetStatusMessage: String?
    @State private var availableTerminalShellPaths = [LocalLinuxTerminalShellConfiguration.defaultPath]

    var body: some View {
        TabView {
            activityTab
                .tabItem { Label(NSLocalizedString("运行", comment: "Local Linux activity tab"), systemImage: "terminal") }
            systemTab
                .tabItem { Label(NSLocalizedString("系统", comment: "Local Linux system tab"), systemImage: "cpu") }
            configurationTab
                .tabItem { Label(NSLocalizedString("配置", comment: "Local Linux configuration tab"), systemImage: "slider.horizontal.3") }
            dataTab
                .tabItem { Label(NSLocalizedString("数据", comment: "Local Linux data tab"), systemImage: "internaldrive") }
        }
        .navigationTitle(NSLocalizedString("本地 Linux", comment: "Local Linux feature title"))
        .task {
            snapshot = await LocalLinuxRuntimeController.shared.refreshInstalledState()
            usage = await LocalLinuxStorageManager.shared.storageUsage()
            await refreshAvailableTerminalShellPaths()
            for await update in await LocalLinuxRuntimeController.shared.updates() {
                if Task.isCancelled { break }
                snapshot = update
            }
        }
        .alert(
            NSLocalizedString("本地 Linux 操作失败", comment: "Local Linux operation error title"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button(NSLocalizedString("好", comment: "Dismiss button"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            NSLocalizedString("重置本地 Linux", comment: "Reset local Linux confirmation title"),
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("删除系统并重新准备", comment: "Reset Linux system action"), role: .destructive) {
                resetSystem()
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(deleteUserData
                 ? NSLocalizedString("将同时删除 Home、Shared 与全部工作区。此操作无法撤销。", comment: "Reset Linux including user data warning")
                 : NSLocalizedString("只删除可重建的系统；Home、Shared 与工作区会保留。运行中的 Linux 会在 App 内停止并重新启动。", comment: "Reset Linux system warning"))
        }
    }

    private var systemTab: some View {
        Form {
            Section {
                LabeledContent(
                    NSLocalizedString("运行时", comment: "Local Linux runtime label"),
                    value: snapshot.phase.displayName
                )
                if let progress = snapshot.installProgress,
                   let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                }
                if let version = snapshot.seedVersion {
                    LabeledContent(NSLocalizedString("Alpine", comment: "Alpine version label"), value: version)
                }
                if let capabilities = snapshot.capabilities {
                    LabeledContent(
                        NSLocalizedString("架构", comment: "Linux architecture label"),
                        value: capabilities.guestArchitecture
                    )
                }
                if let lastError = snapshot.lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if snapshot.phase == .ready, !isPreparingRuntime {
                    Label(
                        NSLocalizedString("系统已就绪", comment: "Local Linux ready action state"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                } else {
                    Button {
                        prepareRuntime()
                    } label: {
                        HStack {
                            if isPreparingRuntime || snapshot.phase == .installing || snapshot.phase == .starting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: runtimePreparationSymbol)
                            }
                            Text(runtimePreparationTitle)
                        }
                    }
                    .disabled(!canPrepareRuntime)
                }
            } header: {
                Text(NSLocalizedString("状态", comment: "Local Linux status section"))
            } footer: {
                if snapshot.phase == .ready {
                    Text(NSLocalizedString("系统已经启动，无需重复准备。终端、Agent 与本地 MCP 会复用当前运行时。", comment: "Local Linux ready footer"))
                }
            }

        }
    }

    private var configurationTab: some View {
        Form {
            Section {
                Picker(
                    NSLocalizedString("聊天缩略图", comment: "Local Linux chat preview setting"),
                    selection: $appConfig.localLinuxChatPreviewMode
                ) {
                    ForEach(LocalLinuxChatPreviewMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.navigationLink)

                if LocalLinuxChatPreviewMode.normalized(appConfig.localLinuxChatPreviewMode) != .off {
                    Picker(
                        NSLocalizedString("显示位置", comment: "Local Linux chat preview placement setting"),
                        selection: $appConfig.localLinuxChatPreviewPlacement
                    ) {
                        ForEach(LocalLinuxChatPreviewPlacement.allCases) { placement in
                            Text(placement.displayName).tag(placement.rawValue)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            } footer: {
                if LocalLinuxChatPreviewMode.normalized(appConfig.localLinuxChatPreviewMode) != .off {
                    Text(NSLocalizedString("悬浮窗可以拖动和收起；输入栏上方会固定在输入区，不遮挡聊天内容。", comment: "Local Linux chat preview placement footer"))
                }
            }

            Section {
                Picker(
                    NSLocalizedString("默认终端 Shell", comment: "Default interactive Linux shell setting"),
                    selection: $appConfig.localLinuxDefaultShellPath
                ) {
                    ForEach(availableTerminalShellPaths, id: \.self) { path in
                        Text(path).tag(path)
                    }
                }
                .pickerStyle(.navigationLink)
            } footer: {
                Text(NSLocalizedString("只列出当前 Linux 系统中已安装的 Shell。新终端会以登录 Shell 启动；Agent 的脚本命令仍固定使用 /bin/sh。", comment: "Default interactive Linux shell footer"))
            }

            Section {
                NavigationLink {
                    LocalLinuxEnvironmentView()
                } label: {
                    Label(NSLocalizedString("环境变量", comment: "Local Linux environment entry"), systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                NavigationLink {
                    LocalAgentPromptProfilesView()
                } label: {
                    Label(NSLocalizedString("Agent 提示词", comment: "Local Agent prompt entry"), systemImage: "text.quote")
                }
                NavigationLink {
                    LocalLinuxSafetyRulesView()
                } label: {
                    Label(NSLocalizedString("命令安全策略", comment: "Local Linux safety entry"), systemImage: "checkmark.shield")
                }
                NavigationLink {
                    LocalLinuxTerminalShortcutSettingsView()
                } label: {
                    Label(NSLocalizedString("终端快捷键", comment: "Local Linux terminal shortcut settings entry"), systemImage: "keyboard")
                }
                NavigationLink {
                    LocalLinuxMountsView()
                } label: {
                    Label(NSLocalizedString("工作区与挂载", comment: "Local Linux mounts entry"), systemImage: "externaldrive.connected.to.line.below")
                }
                NavigationLink {
                    MCPIntegrationView()
                } label: {
                    Label(NSLocalizedString("管理 MCP 服务器", comment: "Local Linux MCP management entry"), systemImage: "server.rack")
                }
            }

            Section {
                Picker(
                    NSLocalizedString("新会话默认模式", comment: "Default local Agent session mode"),
                    selection: $appConfig.localLinuxDefaultSessionMode
                ) {
                    ForEach(LocalAgentMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                LabeledContent(NSLocalizedString("默认命令超时（秒）", comment: "Default Linux command timeout label")) {
                    TextField(
                        "",
                        value: Binding(
                            get: { appConfig.localLinuxDefaultTimeoutSeconds },
                            set: { appConfig.localLinuxDefaultTimeoutSeconds = min(max(0, $0), 4_294_967) }
                        ),
                        format: .number
                    )
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                }
                LabeledContent(NSLocalizedString("发送给模型的输出上限", comment: "Linux model output limit label")) {
                    HStack {
                        TextField(
                            "",
                            value: Binding(
                                get: { max(4, appConfig.localLinuxOutputPreviewBytes / 1_024) },
                                set: { appConfig.localLinuxOutputPreviewBytes = min(max(4, $0), 4_194_303) * 1_024 }
                            ),
                            format: .number
                        )
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        Text(NSLocalizedString("KB", comment: "Kilobyte unit"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 120)
                }
            } footer: {
                Text(NSLocalizedString("0 表示命令不限时。命令输出超过设置大小时，只会截断发送给模型的副本；用户终端仍保留完整输出。", comment: "Local Linux execution defaults footer"))
            }

            Section {
                Toggle(
                    NSLocalizedString("发送给模型前隐藏环境变量值", comment: "Local Linux output privacy toggle"),
                    isOn: $appConfig.localLinuxEnvironmentPrivacyEnabled
                )
            } footer: {
                Text(NSLocalizedString("开启后，命令与本地 MCP 输出中出现已启用环境变量的值时，只会在发送给模型前替换；用户终端和原始日志保持不变。关闭后会原样发送。", comment: "Local Linux model copy redaction footer"))
            }
        }
    }

    private var activityTab: some View {
        Form {
            Section {
                Toggle(
                    NSLocalizedString("启用本地 Linux", comment: "Enable local Linux toggle"),
                    isOn: $appConfig.localLinuxEnabled
                )
            } footer: {
                Text(NSLocalizedString("开启后可使用终端、Agent Linux 工具与本地 MCP；系统仍会在首次使用时按需准备。", comment: "Local Linux run tab enable footer"))
            }

            Section {
                LocalLinuxGuideCard()
            }

            Section {
                NavigationLink {
                    LocalLinuxTerminalView()
                } label: {
                    Label(NSLocalizedString("打开用户终端", comment: "Open user Linux terminal"), systemImage: "terminal")
                }
                .disabled(!appConfig.localLinuxEnabled)

                NavigationLink {
                    LocalLinuxJobsView(sessionID: sessionID)
                } label: {
                    Label(NSLocalizedString("任务与终端", comment: "Local Linux jobs entry"), systemImage: "list.bullet.rectangle")
                }

                NavigationLink {
                    LocalLinuxRecipesView()
                } label: {
                    Label(NSLocalizedString("安装常用环境", comment: "Local Linux recipes entry"), systemImage: "shippingbox")
                }
                .disabled(!appConfig.localLinuxEnabled)
            }

            Section(NSLocalizedString("当前活动", comment: "Local Linux current activity section")) {
                LabeledContent(NSLocalizedString("命令与浏览器任务", comment: "Local Agent job count"), value: "\(snapshot.activeJobCount)")
                LabeledContent(NSLocalizedString("终端", comment: "Linux terminal count"), value: "\(snapshot.activeTerminalCount)")
                LabeledContent(NSLocalizedString("本地 MCP", comment: "Local MCP count"), value: "\(snapshot.activeMCPProcessCount)")
            }
            LocalLinuxResourceStatusSection()
        }
    }

    private var dataTab: some View {
        Form {
            Section {
                NavigationLink {
                    LocalLinuxFileBrowserView()
                } label: {
                    Label(NSLocalizedString("浏览 Linux 文件", comment: "Browse Linux files"), systemImage: "folder")
                }
                .disabled(!appConfig.localLinuxEnabled)
            } footer: {
                Text(NSLocalizedString("系统文件可自由修改；损坏后可通过重置重新准备。", comment: "Linux file browser warning"))
            }

            Section(NSLocalizedString("存储", comment: "Local Linux storage section")) {
                storageRow(NSLocalizedString("系统", comment: "Linux system storage"), bytes: usage.systemBytes)
                storageRow(NSLocalizedString("Home", comment: "Linux home storage"), bytes: usage.homeBytes)
                storageRow(NSLocalizedString("Shared", comment: "Linux shared storage"), bytes: usage.sharedBytes)
                storageRow(NSLocalizedString("工作区", comment: "Linux workspace storage"), bytes: usage.workspaceBytes)
                storageRow(NSLocalizedString("导出", comment: "Linux exports storage"), bytes: usage.exportBytes)
                Button(NSLocalizedString("重新统计", comment: "Refresh Linux storage usage")) {
                    Task { usage = await LocalLinuxStorageManager.shared.storageUsage() }
                }
                NavigationLink(NSLocalizedString("许可与源码", comment: "Local Linux compliance entry")) {
                    LocalLinuxComplianceView()
                }
            }

            Section(NSLocalizedString("重置", comment: "Local Linux reset section")) {
                Toggle(
                    NSLocalizedString("同时删除用户数据", comment: "Delete Linux user data toggle"),
                    isOn: $deleteUserData
                )
                .disabled(isResettingSystem)
                if isResettingSystem {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(NSLocalizedString("正在重置并重新启动 Linux…", comment: "Resetting local Linux status"))
                    }
                } else if let resetStatusMessage {
                    Label(resetStatusMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button(NSLocalizedString("重置本地 Linux…", comment: "Reset local Linux action"), role: .destructive) {
                    showResetConfirmation = true
                }
                .disabled(isResettingSystem)
            }
        }
    }

    @MainActor
    private func refreshAvailableTerminalShellPaths() async {
        let paths = await LocalLinuxStorageManager.shared.availableTerminalShellPaths()
        availableTerminalShellPaths = paths
        let configuredPath = LocalLinuxTerminalShellConfiguration.normalizedPath(
            appConfig.localLinuxDefaultShellPath
        )
        appConfig.localLinuxDefaultShellPath = paths.contains(configuredPath)
            ? configuredPath
            : LocalLinuxTerminalShellConfiguration.defaultPath
    }

    private func storageRow(_ title: String, bytes: UInt64) -> some View {
        LabeledContent(title, value: ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))
    }

    private func prepareRuntime() {
        guard canPrepareRuntime else { return }
        isPreparingRuntime = true
        Task {
            defer { isPreparingRuntime = false }
            do {
                if snapshot.phase == .requiresRelaunch {
                    snapshot = try await LocalLinuxRuntimeController.shared.restartRuntime()
                } else {
                    snapshot = try await LocalLinuxRuntimeController.shared.ensureReady(trigger: .recipe)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var canPrepareRuntime: Bool {
        guard appConfig.localLinuxEnabled, !isPreparingRuntime else { return false }
        switch snapshot.phase {
        case .installing, .starting, .ready:
            return false
        default:
            return true
        }
    }

    private var runtimePreparationTitle: String {
        if isPreparingRuntime,
           snapshot.phase != .installing,
           snapshot.phase != .starting {
            return LocalLinuxRuntimePhase.installing.displayName
        }
        switch snapshot.phase {
        case .installing, .starting:
            return snapshot.phase.displayName
        case .requiresRelaunch:
            return NSLocalizedString("重新启动 Linux", comment: "Restart local Linux action")
        default:
            return NSLocalizedString("准备并启动系统", comment: "Prepare local Linux action")
        }
    }

    private var runtimePreparationSymbol: String {
        switch snapshot.phase {
        case .degraded, .failed:
            return "arrow.clockwise.circle"
        default:
            return "play.circle"
        }
    }

    private func resetSystem() {
        guard !isResettingSystem else { return }
        isResettingSystem = true
        resetStatusMessage = nil
        Task {
            defer { isResettingSystem = false }
            do {
                snapshot = try await LocalLinuxRuntimeController.shared.deleteSystem(deleteUserData: deleteUserData)
                usage = await LocalLinuxStorageManager.shared.storageUsage()
                resetStatusMessage = appConfig.localLinuxEnabled
                    ? NSLocalizedString("系统已重置并重新启动。", comment: "Local Linux reset completed")
                    : NSLocalizedString("系统已重置；下次启用时会重新准备。", comment: "Disabled local Linux reset completed")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct LocalLinuxEnvironmentView: View {
    @State private var variables: [LocalLinuxEnvironmentVariable] = []

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    LocalLinuxEnvironmentEditorView(variable: nil)
                } label: {
                    Label(NSLocalizedString("添加环境变量", comment: "Add Linux environment variable"), systemImage: "plus")
                }
            }

            Section {
                if variables.isEmpty {
                    Text(NSLocalizedString("还没有环境变量。", comment: "No Linux environment variables"))
                        .foregroundStyle(.secondary)
                }
                ForEach(variables) { variable in
                    NavigationLink {
                        LocalLinuxEnvironmentEditorView(variable: variable)
                    } label: {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(variable.name).font(.body.monospaced())
                                if !variable.isEnabled {
                                    Text(NSLocalizedString("已停用", comment: "Disabled Linux environment variable"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text("••••••••")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            if !variable.note.isEmpty {
                                Text(variable.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("变量", comment: "Linux environment variables section"))
            } footer: {
                Text(NSLocalizedString("已启用的变量会自动注入新建的命令、终端与本地 MCP 进程。列表始终隐藏值；点进变量即可查看和编辑。", comment: "Environment variable visibility footer"))
            }
        }
        .navigationTitle(NSLocalizedString("环境变量", comment: "Linux environment title"))
        .task { await reload() }
        .onAppear { Task { await reload() } }
    }

    private func reload() async {
        variables = await LocalLinuxProcessEnvironmentProvider.shared.variables()
    }
}

private struct LocalLinuxEnvironmentEditorView: View {
    @Environment(\.dismiss) private var dismiss
    private let isNew: Bool
    @State private var draft: LocalLinuxEnvironmentVariable
    @State private var errorMessage: String?

    init(variable: LocalLinuxEnvironmentVariable?) {
        isNew = variable == nil
        _draft = State(initialValue: variable ?? LocalLinuxEnvironmentVariable(name: "", value: ""))
    }

    var body: some View {
        Form {
            Section {
                TextField(NSLocalizedString("名称", comment: "Environment variable name"), text: $draft.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(NSLocalizedString("值", comment: "Environment variable value"), text: $draft.value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(NSLocalizedString("备注（可选）", comment: "Environment variable note"), text: $draft.note)
                Toggle(NSLocalizedString("启用", comment: "Enable Linux environment variable"), isOn: $draft.isEnabled)
            } footer: {
                Text(NSLocalizedString("变量只在新建 Linux 进程、终端或本地 MCP 时注入；不会写入 shell 配置文件，也不会自动加入模型上下文。", comment: "Linux environment editor footer"))
            }

            Section {
                Button(NSLocalizedString("保存", comment: "Save"), action: save)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !isNew {
                    Button(NSLocalizedString("删除变量", comment: "Delete Linux environment variable"), role: .destructive) {
                        deleteVariable()
                    }
                }
            }
        }
        .navigationTitle(isNew
            ? NSLocalizedString("添加环境变量", comment: "Add Linux environment variable title")
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

private struct LocalLinuxSafetyRulesView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var rules: [LocalLinuxCommandRule] = []

    var body: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("启用命令安全策略", comment: "Enable Linux command safety"), isOn: $appConfig.localLinuxCommandSafetyEnabled)
            } footer: {
                Text(NSLocalizedString("策略可以警告、要求确认或拒绝命令。关闭后将以完全权限执行；不会内置不可关闭的命令黑名单。", comment: "Linux command safety footer"))
            }

            Section {
                NavigationLink {
                    LocalLinuxSafetyRuleEditorView(
                        rule: LocalLinuxCommandRule(
                            name: "",
                            pattern: "",
                            matchKind: .prefix,
                            scope: .all,
                            action: .confirm,
                            sortIndex: rules.count
                        )
                    )
                } label: {
                    Label(NSLocalizedString("添加规则", comment: "Add Linux rule"), systemImage: "plus")
                }
            }

            Section(NSLocalizedString("规则", comment: "Linux rules section")) {
                if rules.isEmpty {
                    Text(NSLocalizedString("还没有命令规则。", comment: "No Linux command safety rules"))
                        .foregroundStyle(.secondary)
                }
                ForEach(rules) { rule in
                    NavigationLink {
                        LocalLinuxSafetyRuleEditorView(rule: rule)
                    } label: {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(rule.name)
                                if !rule.isEnabled {
                                    Text(NSLocalizedString("已停用", comment: "Disabled Linux command rule"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(rule.pattern).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("\(rule.action.displayName) · \(rule.scope.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                            Task {
                                try? await LocalLinuxApprovalPolicy.shared.delete(id: rule.id)
                                await reload()
                            }
                        }
                    }
                }
                .onMove(perform: moveRules)
            }
        }
        .navigationTitle(NSLocalizedString("安全策略", comment: "Linux safety title"))
        .toolbar { EditButton() }
        .task { await reload() }
        .onAppear { Task { await reload() } }
    }

    private func reload() async {
        rules = await LocalLinuxApprovalPolicy.shared.rules()
    }

    private func moveRules(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        let reordered = rules.enumerated().map { index, rule -> LocalLinuxCommandRule in
            var updated = rule
            updated.sortIndex = index
            updated.updatedAt = Date()
            return updated
        }
        rules = reordered
        Task {
            for rule in reordered {
                try? await LocalLinuxApprovalPolicy.shared.save(rule)
            }
            await reload()
        }
    }
}

private struct LocalLinuxSafetyRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LocalLinuxCommandRule
    @State private var validationMessage: String?
    @State private var saveError: String?

    init(rule: LocalLinuxCommandRule) {
        _draft = State(initialValue: rule)
    }

    var body: some View {
        Form {
            Section {
                TextField(NSLocalizedString("规则名称", comment: "Linux rule name"), text: $draft.name)
                TextField(NSLocalizedString("匹配内容", comment: "Linux rule pattern"), text: $draft.pattern)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let validationMessage {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Picker(NSLocalizedString("匹配方式", comment: "Linux rule match kind"), selection: $draft.matchKind) {
                    ForEach(LocalLinuxCommandRuleMatchKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                Picker(NSLocalizedString("作用范围", comment: "Linux command rule scope"), selection: $draft.scope) {
                    ForEach(LocalLinuxCommandRuleScope.allCases, id: \.self) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                Picker(NSLocalizedString("处理", comment: "Linux rule action"), selection: $draft.action) {
                    ForEach(LocalLinuxCommandRuleAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                Toggle(NSLocalizedString("启用规则", comment: "Enable Linux command rule"), isOn: $draft.isEnabled)
            } footer: {
                Text(NSLocalizedString("规则只用于提示、确认或拒绝匹配文本；它不是 shell sandbox。关闭总开关后不会保留隐藏黑名单。", comment: "Linux command rule editor footer"))
            }

            Section {
                Button(NSLocalizedString("保存", comment: "Save"), action: save)
                    .disabled(
                        draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || validationMessage != nil
                    )
            }
        }
        .navigationTitle(draft.name.isEmpty
            ? NSLocalizedString("命令规则", comment: "Linux command rule title")
            : draft.name)
        .task { validatePattern() }
        .onChange(of: draft.pattern) { _, _ in validatePattern() }
        .onChange(of: draft.matchKind) { _, _ in validatePattern() }
        .alert(NSLocalizedString("保存失败", comment: "Save failed"), isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button(NSLocalizedString("好", comment: "Dismiss"), role: .cancel) {}
        } message: { Text(saveError ?? "") }
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
                } catch {
                    return error.localizedDescription
                }
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
            } catch { saveError = error.localizedDescription }
        }
    }
}

private struct LocalLinuxMountsView: View {
    @State private var mounts: [LocalLinuxMountRecord] = []
    @State private var isImporterPresented = false
    @State private var isPreparingMount = false
    @State private var access = LocalLinuxMountAccess.readOnly
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                NavigationLink(NSLocalizedString("管理工作区", comment: "Manage Linux workspaces")) {
                    LocalLinuxWorkspacesView()
                }
            }

            Section {
                Picker(NSLocalizedString("新挂载权限", comment: "New Linux mount access"), selection: $access) {
                    Text(NSLocalizedString("只读", comment: "Read only" )).tag(LocalLinuxMountAccess.readOnly)
                    Text(NSLocalizedString("读写", comment: "Read write")).tag(LocalLinuxMountAccess.readWrite)
                }
                Button(NSLocalizedString("选择外部文件夹…", comment: "Choose external Linux mount")) {
                    isImporterPresented = true
                }
                if isPreparingMount {
                    HStack {
                        ProgressView()
                        Text(NSLocalizedString("正在准备文件", comment: "Linux mount materializing"))
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(NSLocalizedString("外部目录使用系统授权书签；只读权限会在存储管理和 Linux mount 层执行。iCloud Drive 固定映射到 /mnt/icloud。", comment: "Linux mount behavior footer"))
            }

            Section(NSLocalizedString("外部挂载", comment: "External Linux mounts section")) {
                if mounts.isEmpty {
                    Text(NSLocalizedString("还没有外部挂载。", comment: "No external Linux mounts"))
                        .foregroundStyle(.secondary)
                }
                ForEach(mounts) { mount in
                    NavigationLink {
                        LocalLinuxMountDetailView(record: mount)
                    } label: {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(mount.displayName)
                                if !mount.isEnabled {
                                    Text(NSLocalizedString("已停用", comment: "Disabled Linux mount"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(mount.guestPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("\(mount.access.displayName) · \(mount.authorizationState.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if mount.activeLeaseCount > 0 {
                                Text(String(
                                    format: NSLocalizedString("%lld 个任务正在使用", comment: "Linux mount active lease count"),
                                    mount.activeLeaseCount
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("工作区与挂载", comment: "Linux mounts title"))
        .task { await reload() }
        .onAppear { Task { await reload() } }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                Task {
                    isPreparingMount = true
                    defer { isPreparingMount = false }
                    do {
                        _ = try await LocalLinuxMountManager.shared.addExternalDirectory(
                            url,
                            displayName: url.lastPathComponent,
                            access: access
                        )
                        await reload()
                    } catch {
                        await reload()
                        errorMessage = error.localizedDescription
                    }
                }
            } catch { errorMessage = error.localizedDescription }
        }
        .alert(NSLocalizedString("挂载失败", comment: "Mount failed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(NSLocalizedString("好", comment: "Dismiss"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func reload() async { mounts = await LocalLinuxMountManager.shared.records() }
}

private struct LocalLinuxMountDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var record: LocalLinuxMountRecord
    @State private var requestedAccess: LocalLinuxMountAccess
    @State private var isImporterPresented = false
    @State private var isPreparingMount = false
    @State private var showRemovalConfirmation = false
    @State private var errorMessage: String?

    init(record: LocalLinuxMountRecord) {
        _record = State(initialValue: record)
        _requestedAccess = State(initialValue: record.access)
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("挂载", comment: "Linux mount detail section")) {
                LabeledContent(NSLocalizedString("目录", comment: "Linux mount directory"), value: record.displayName)
                LabeledContent(NSLocalizedString("Linux 路径", comment: "Linux mount guest path"), value: record.guestPath)
                LabeledContent(NSLocalizedString("授权", comment: "Linux mount authorization"), value: record.authorizationState.displayName)
                LabeledContent(NSLocalizedString("使用中", comment: "Linux mount active leases"), value: "\(record.activeLeaseCount)")
                Toggle(NSLocalizedString("启用挂载", comment: "Enable Linux mount"), isOn: enabledBinding)
            }

            Section {
                Picker(NSLocalizedString("重新授权后的权限", comment: "Linux mount requested access"), selection: $requestedAccess) {
                    ForEach(LocalLinuxMountAccess.allCases, id: \.self) { access in
                        Text(access.displayName).tag(access)
                    }
                }
                Button(record.authorizationState == .needsReauthorization
                    ? NSLocalizedString("重新选择目录…", comment: "Reauthorize Linux mount")
                    : NSLocalizedString("重新选择目录并应用权限…", comment: "Reselect Linux mount and apply access")) {
                    isImporterPresented = true
                }
                if isPreparingMount {
                    HStack {
                        ProgressView()
                        Text(NSLocalizedString("正在准备文件", comment: "Linux mount materializing"))
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(NSLocalizedString("提升为读写需要再次通过系统文件选择器确认目录。活跃任务持有租约时，请先停止任务再普通卸载。", comment: "Linux mount reauthorization footer"))
            }

            Section {
                Button(NSLocalizedString("移除挂载…", comment: "Remove Linux mount"), role: .destructive) {
                    showRemovalConfirmation = true
                }
            }
        }
        .navigationTitle(record.displayName)
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                Task {
                    isPreparingMount = true
                    defer { isPreparingMount = false }
                    do {
                        record = try await LocalLinuxMountManager.shared.reauthorize(
                            id: record.id,
                            with: url,
                            access: requestedAccess
                        )
                    } catch {
                        let records = await LocalLinuxMountManager.shared.records()
                        if let updated = records.first(where: { $0.id == record.id }) {
                            record = updated
                        }
                        errorMessage = error.localizedDescription
                    }
                }
            } catch { errorMessage = error.localizedDescription }
        }
        .confirmationDialog(
            NSLocalizedString("移除此挂载？", comment: "Remove Linux mount confirmation"),
            isPresented: $showRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("移除挂载", comment: "Remove Linux mount"), role: .destructive) {
                remove(force: false)
            }
            if record.activeLeaseCount > 0 {
                Button(NSLocalizedString("立即停止使用并移除", comment: "Force remove Linux mount"), role: .destructive) {
                    remove(force: true)
                }
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("移除只会撤销 Linux 的目录入口，不会删除外部文件。强制移除可能中断正在使用它的任务。", comment: "Remove Linux mount warning"))
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
