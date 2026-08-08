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

    var body: some View {
        TabView {
            systemTab
                .tabItem { Label(NSLocalizedString("系统", comment: "Local Linux system tab"), systemImage: "cpu") }
            configurationTab
                .tabItem { Label(NSLocalizedString("配置", comment: "Local Linux configuration tab"), systemImage: "slider.horizontal.3") }
            activityTab
                .tabItem { Label(NSLocalizedString("运行", comment: "Local Linux activity tab"), systemImage: "terminal") }
            dataTab
                .tabItem { Label(NSLocalizedString("数据", comment: "Local Linux data tab"), systemImage: "internaldrive") }
        }
        .navigationTitle(NSLocalizedString("本地 Linux", comment: "Local Linux feature title"))
        .task {
            snapshot = await LocalLinuxRuntimeController.shared.refreshInstalledState()
            usage = await LocalLinuxStorageManager.shared.storageUsage()
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
                 : NSLocalizedString("只删除可重建的系统；Home、Shared 与工作区会保留。运行中的系统需要重新打开 App。", comment: "Reset Linux system warning"))
        }
    }

    private var systemTab: some View {
        Form {
            Section {
                Toggle(
                    NSLocalizedString("启用本地 Linux", comment: "Enable local Linux toggle"),
                    isOn: $appConfig.localLinuxEnabled
                )
            } footer: {
                Text(NSLocalizedString("开启这里只允许使用功能，不会下载、安装或启动系统。首次打开终端、Linux 文件、recipe 或运行 Agent 工具时才会准备内置环境。", comment: "Local Linux lazy start footer"))
            }

            Section(NSLocalizedString("状态", comment: "Local Linux status section")) {
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
                Button(NSLocalizedString("准备并启动系统", comment: "Prepare local Linux action")) {
                    prepareRuntime()
                }
                .disabled(!appConfig.localLinuxEnabled || snapshot.phase == .installing || snapshot.phase == .starting)
            }

            Section(NSLocalizedString("兼容性", comment: "Local Linux compatibility section")) {
                Text(NSLocalizedString("命令失败时会保留退出码、信号、errno 和 iSH 兼容性诊断。反馈助手可以引用诊断编号，不会把未打码的环境变量输出交给模型。", comment: "Local Linux diagnostics explanation"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var configurationTab: some View {
        Form {
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
                TextField(
                    NSLocalizedString("默认超时（秒，0 表示不限）", comment: "Default Linux command timeout"),
                    value: Binding(
                        get: { appConfig.localLinuxDefaultTimeoutSeconds },
                        set: { appConfig.localLinuxDefaultTimeoutSeconds = min(max(0, $0), 4_294_967) }
                    ),
                    format: .number
                )
                .keyboardType(.numberPad)
                TextField(
                    NSLocalizedString("模型输出预览（字节）", comment: "Linux model output preview bytes"),
                    value: Binding(
                        get: { appConfig.localLinuxOutputPreviewBytes },
                        set: { appConfig.localLinuxOutputPreviewBytes = max(4_096, $0) }
                    ),
                    format: .number
                )
                .keyboardType(.numberPad)
                Toggle(
                    NSLocalizedString("模型输出按环境变量值打码", comment: "Local Linux output privacy toggle"),
                    isOn: $appConfig.localLinuxEnvironmentPrivacyEnabled
                )
            } footer: {
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("环境变量在创建 Linux 进程时 export，不会改写 .profile 或 .zshrc。原始输出仍归用户所有；只有发给模型的副本按值匹配打码。", comment: "Local Linux environment behavior footer"))
                    Text(NSLocalizedString("0 秒表示不限时；预览限制不截断用户原始日志。", comment: "Local Linux execution defaults footer"))
                }
            }
        }
    }

    private var activityTab: some View {
        Form {
            Section {
                NavigationLink {
                    LocalLinuxTerminalView(sessionID: sessionID)
                } label: {
                    Label(NSLocalizedString("打开用户终端", comment: "Open user Linux terminal"), systemImage: "terminal")
                }
                .disabled(sessionID == nil || !appConfig.localLinuxEnabled)

                NavigationLink {
                    LocalLinuxJobsView(sessionID: sessionID)
                } label: {
                    Label(NSLocalizedString("任务与终端", comment: "Local Linux jobs entry"), systemImage: "list.bullet.rectangle")
                }

                NavigationLink {
                    LocalLinuxRecipesView(sessionID: sessionID)
                } label: {
                    Label(NSLocalizedString("安装常用环境", comment: "Local Linux recipes entry"), systemImage: "shippingbox")
                }
                .disabled(sessionID == nil || !appConfig.localLinuxEnabled)
            } footer: {
                Text(NSLocalizedString("用户终端与 Agent 命令会话彼此独立，但共享系统和当前会话工作区。不会限制终端、子代理或并行任务数量。", comment: "Local Linux independent terminals footer"))
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
                Text(NSLocalizedString("这里通过 Linux 文件接口访问 RootFS 和挂载。删除系统文件可能让环境损坏，但不会被硬拦截。", comment: "Linux file browser warning"))
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
                Button(NSLocalizedString("重置本地 Linux…", comment: "Reset local Linux action"), role: .destructive) {
                    showResetConfirmation = true
                }
            }
        }
    }

    private func storageRow(_ title: String, bytes: UInt64) -> some View {
        LabeledContent(title, value: ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))
    }

    private func prepareRuntime() {
        Task {
            do {
                snapshot = try await LocalLinuxRuntimeController.shared.ensureReady(trigger: .recipe)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resetSystem() {
        Task {
            do {
                try await LocalLinuxRuntimeController.shared.deleteSystem(deleteUserData: deleteUserData)
                usage = await LocalLinuxStorageManager.shared.storageUsage()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct LocalLinuxEnvironmentView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var variables: [LocalLinuxEnvironmentVariable] = []
    @State private var showsValues = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    NSLocalizedString("显示环境变量值", comment: "Show Linux environment values"),
                    isOn: $showsValues
                )
                NavigationLink {
                    LocalLinuxEnvironmentEditorView(variable: nil)
                } label: {
                    Label(NSLocalizedString("添加环境变量", comment: "Add Linux environment variable"), systemImage: "plus")
                }
            }

            Section(NSLocalizedString("变量", comment: "Linux environment variables section")) {
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
                            Text(showsValues ? variable.value : "••••••••")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            if !variable.note.isEmpty {
                                Text(variable.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Toggle(
                    NSLocalizedString("模型副本打码", comment: "Environment redaction toggle"),
                    isOn: $appConfig.localLinuxEnvironmentPrivacyEnabled
                )
            } footer: {
                Text(NSLocalizedString("这些值只在启动进程时注入。Agent 不能直接读取设置列表，但可以像普通 Linux 程序一样执行 echo 等命令查看进程环境。", comment: "Environment variable visibility footer"))
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
    @State private var showsValue = false
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
                if showsValue {
                    TextField(NSLocalizedString("值", comment: "Environment variable value"), text: $draft.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField(NSLocalizedString("值", comment: "Environment variable value"), text: $draft.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle(NSLocalizedString("显示值", comment: "Show environment variable value"), isOn: $showsValue)
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

private struct LocalAgentPromptProfilesView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var profiles: [LocalAgentPromptProfile] = []
    @State private var selectedID = LocalAgentPromptStore.builtInProfileID
    @State private var content = ""
    @State private var newProfileTitle = ""

    var body: some View {
        Form {
            Section {
                Picker(NSLocalizedString("提示词", comment: "Agent prompt profile picker"), selection: $selectedID) {
                    ForEach(profiles) { profile in
                        Text(profile.title).tag(profile.id)
                    }
                }
                .onChange(of: selectedID) { _, id in select(id) }
                TextEditor(text: $content)
                    .frame(minHeight: 260)
                    .font(.body.monospaced())
                Button(NSLocalizedString("保存", comment: "Save"), action: save)
                Button(NSLocalizedString("清空当前提示词", comment: "Clear current Agent prompt"), role: .destructive) {
                    content = ""
                }
                Button(NSLocalizedString("恢复默认提示词", comment: "Reset default Agent prompt")) {
                    Task {
                        _ = try? await LocalAgentPromptStore.shared.resetBuiltInProfile()
                        appConfig.localLinuxActivePromptProfileID = LocalAgentPromptStore.builtInProfileID.uuidString
                        selectedID = LocalAgentPromptStore.builtInProfileID
                        await reload()
                    }
                }
                if selectedID != LocalAgentPromptStore.builtInProfileID {
                    Button(NSLocalizedString("删除当前提示词", comment: "Delete current Agent prompt"), role: .destructive) {
                        deleteSelectedProfile()
                    }
                }
            } footer: {
                Text(NSLocalizedString("只有 Agent 模式会插入这里的提示词；Chat 模式继续使用普通聊天系统提示词。", comment: "Agent prompt scope footer"))
            }

            Section(NSLocalizedString("新建提示词", comment: "Create Agent prompt profile section")) {
                TextField(NSLocalizedString("名称", comment: "Agent prompt profile name"), text: $newProfileTitle)
                Button(NSLocalizedString("新建", comment: "Create Agent prompt profile"), action: createProfile)
                    .disabled(newProfileTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(NSLocalizedString("Agent 提示词", comment: "Agent prompt title"))
        .task { await reload() }
    }

    private func reload() async {
        profiles = await LocalAgentPromptStore.shared.profiles()
        if let configured = UUID(uuidString: appConfig.localLinuxActivePromptProfileID),
           profiles.contains(where: { $0.id == configured }) {
            selectedID = configured
        }
        select(selectedID)
    }

    private func select(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        content = profile.content
        appConfig.localLinuxActivePromptProfileID = id.uuidString
    }

    private func save() {
        guard var profile = profiles.first(where: { $0.id == selectedID }) else { return }
        profile.content = content
        profile.updatedAt = Date()
        Task {
            try? await LocalAgentPromptStore.shared.save(profile)
            await reload()
        }
    }

    private func createProfile() {
        let title = newProfileTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let profile = LocalAgentPromptProfile(title: title, content: content)
        newProfileTitle = ""
        selectedID = profile.id
        Task {
            try? await LocalAgentPromptStore.shared.save(profile)
            appConfig.localLinuxActivePromptProfileID = profile.id.uuidString
            await reload()
        }
    }

    private func deleteSelectedProfile() {
        let id = selectedID
        selectedID = LocalAgentPromptStore.builtInProfileID
        Task {
            try? await LocalAgentPromptStore.shared.delete(id: id)
            appConfig.localLinuxActivePromptProfileID = LocalAgentPromptStore.builtInProfileID.uuidString
            await reload()
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
                TextField(NSLocalizedString("命令前缀或正则", comment: "Linux rule pattern"), text: $draft.pattern)
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
                Text(NSLocalizedString("外部目录使用系统授权书签；只读权限会在 Linux mount 层执行。iCloud Drive 固定映射到 /mnt/icloud。", comment: "Linux mount behavior footer"))
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
