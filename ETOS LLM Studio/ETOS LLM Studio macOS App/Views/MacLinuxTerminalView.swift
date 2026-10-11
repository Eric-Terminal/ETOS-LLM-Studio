import Combine
import ETOSCore
import SwiftUI

struct MacLinuxTerminalView: View {
    let isActive: Bool
    @ObservedObject var runtime: MacLinuxModel
    var initialJobID: UUID? = nil
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacLinuxTerminalModel()
    @State private var visible = false
    @State private var endingTerminal = false
    private var active: Bool { visible && isActive && workspace.canManageLocalModels && !runtime.isSuspended }

    var body: some View {
        VStack {
            HStack {
                Menu(NSLocalizedString("切换或新建终端", comment: "")) {
                    ForEach(model.terminals) { terminal in Button(terminal.title) { model.select(terminal) } }
                    Divider()
                    Button(NSLocalizedString("新建终端", comment: "")) { model.createTerminal() }
                        .disabled(!configuration.localLinuxEnabled)
                }.disabled(!model.canOperate)
                if let job = model.job { Text(job.state.displayName).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                NavigationLink {
                    Form {
                        Text(NSLocalizedString("mac.shell.terminal.help", value: "Create or select a native macOS terminal. Input runs in the system Shell. Closing this page keeps the task running; End Terminal stops it. The guide cannot type commands.", comment: "")).textSelection(.enabled)
                    }.formStyle(.grouped)
                        .navigationTitle(NSLocalizedString("使用说明", comment: ""))
                        .guideSettingsPageContext(id: "mac-linux-terminal-introduction", title: NSLocalizedString("使用说明", comment: ""),
                            documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                            isActive: isActive && workspace.canManageLocalModels && !runtime.isSuspended,
                            settings: [.readOnly("read_only", label: NSLocalizedString("使用说明", comment: ""), value: { .bool(true) })])
                } label: { Label(NSLocalizedString("使用说明", comment: ""), systemImage: "info.circle") }
            }.padding().buttonStyle(.borderless)
            GeometryReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.output.isEmpty {
                            Text(NSLocalizedString("mac.shell.terminal.empty", value: "Create or select a terminal to use the macOS Shell.", comment: "")).foregroundStyle(.secondary)
                        }
                        ForEach(model.output) { line in Text(line.displayText).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .padding().frame(minWidth: proxy.size.width, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .background(colorScheme == .dark ? Color.black : Color.white)
                .contextMenu { Button(NSLocalizedString("复制", comment: "")) { model.copyOutput() }.disabled(model.output.isEmpty) }
                .onAppear { resize(proxy.size) }.onChange(of: proxy.size) { _, size in resize(size) }
            }
            if model.inputOwner != .user, model.isTerminalActive {
                Text(NSLocalizedString("输入由 Agent 控制；发送内容即可接管", comment: "")).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(model.shortcuts) { key in Button(key.title) { model.send(key.data) } }
                }.buttonStyle(.borderless).padding(.horizontal)
            }.disabled(!model.canOperate || !model.isTerminalActive)
            HStack {
                TextField(NSLocalizedString("输入命令或终端内容", comment: ""), text: $model.input)
                    .font(.body.monospaced()).onSubmit { model.sendInput() }
                Button(NSLocalizedString("发送到终端", comment: "")) { model.sendInput() }
            }.padding().disabled(!model.canOperate || !model.isTerminalActive)
            HStack {
                if model.inputOwner == .user, model.job?.runID != nil {
                    Button(NSLocalizedString("将输入交还 Agent", comment: "")) { model.returnToAgent() }
                }
                Button(NSLocalizedString("中断前台程序", comment: "")) { model.interrupt() }
                Button(NSLocalizedString("结束终端", comment: ""), role: .destructive) { endingTerminal = true }
            }.padding(.horizontal).buttonStyle(.borderless).disabled(!model.canOperate || !model.isTerminalActive)
            if model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled).padding() }
        }
        .navigationTitle(NSLocalizedString("终端", comment: ""))
        .disabled(!isActive || !workspace.canManageLocalModels || runtime.isSuspended)
        .onAppear { visible = true; open() }
        .onDisappear { visible = false; endingTerminal = false; model.leave() }
        .onChange(of: active) { _, value in if value { open() } else { endingTerminal = false; model.leave() } }
        .onChange(of: colorScheme) { _, value in model.changeAppearance(value == .dark ? .dark : .light) }
        .onChange(of: runtime.epoch) { _, _ in endingTerminal = false; model.leave(); open() }
        .onChange(of: configuration.appLanguage) { _, _ in model.reloadMetadata() }
        .onChange(of: configuration.localLinuxTerminalShortcutIDs) { _, _ in model.reloadMetadata() }
        .onReceive(NotificationCenter.default.publisher(for: .localLinuxConfigurationDidChange).receive(on: DispatchQueue.main)) { _ in model.reloadMetadata() }
        .confirmationDialog(NSLocalizedString("结束终端", comment: ""), isPresented: $endingTerminal, titleVisibility: .visible) {
            Button(NSLocalizedString("结束终端", comment: ""), role: .destructive) { if active { model.endTerminal() } }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-terminal-\(model.lease)-\(runtime.epoch)"), title: NSLocalizedString("终端", comment: ""),
            documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && !endingTerminal,
            settings: [
                .readOnly("job_id", label: NSLocalizedString("终端", comment: ""), value: { .string(model.job?.id.uuidString ?? "") }),
                .readOnly("terminal_count", label: NSLocalizedString("终端", comment: ""), value: { .int(model.terminals.count) }),
                .readOnly("is_active", label: NSLocalizedString("运行中", comment: ""), value: { .bool(model.isTerminalActive) }),
                .readOnly("user_owns_input", label: NSLocalizedString("输入", comment: ""), value: { .bool(model.inputOwner == .user) }),
                .readOnly("manual_input_only", label: NSLocalizedString("发送到终端", comment: ""), value: { .bool(true) })
            ]
        )
    }

    private func open() {
        guard active else { return }
        model.open(initialJobID: initialJobID, appearance: colorScheme == .dark ? .dark : .light)
    }

    private func resize(_ size: CGSize) {
        // 与移动端一样使用有界字符网格；几何变化不触发输出解析或磁盘读取。
        model.resize(columns: UInt16(min(500, max(20, (size.width - 32) / 8))), rows: UInt16(min(200, max(5, (size.height - 32) / 19))))
    }
}
