import Combine
import ETOSCore
import SwiftUI

@MainActor
private final class MacTerminalPreviewModel: ObservableObject {
    @Published private(set) var jobID: UUID?
    @Published private(set) var lines: [LocalLinuxTerminalDisplayLine] = []
    private var observation: Task<Void, Never>?
    private var output: Task<Void, Never>?
    private var lease = UUID()

    func open(appearance: LocalLinuxTerminalAppearance) {
        stop()
        let lease = lease
        observation = Task { [weak self] in
            let services = await MacLinuxServices.shared.value
            for await _ in await services.runtime.updates() {
                guard !Task.isCancelled, let self, self.lease == lease else { return }
                let jobs = await services.scheduler.activeStandaloneUserTerminals()
                guard !Task.isCancelled, self.lease == lease else { return }
                let selected = jobs.first(where: { $0.id == self.jobID })?.id ?? jobs.first?.id
                guard jobID != selected else { continue }
                jobID = selected; output?.cancel(); lines = []
                guard let selected else { continue }
                // 只订阅输出，不更改终端尺寸、不接管输入，也不创建新终端。
                output = Task { [weak self] in
                    do {
                        let stream = try await services.scheduler.terminalDisplayUpdates(jobID: selected, appearance: appearance, minimumInterval: .milliseconds(200))
                        for await value in stream {
                            guard !Task.isCancelled, let self, self.lease == lease else { return }
                            lines = Array(value.suffix(4))
                        }
                    } catch { if !Task.isCancelled, self?.lease == lease { self?.lines = [] } }
                }
            }
        }
    }

    func stop() {
        lease = UUID(); observation?.cancel(); output?.cancel()
        observation = nil; output = nil; jobID = nil; lines = []
    }
    deinit { observation?.cancel(); output?.cancel() }
}

struct MacChatExecutionPreview: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var terminal = MacTerminalPreviewModel()
    @State private var tool: AgentToolExecutionPreviewSnapshot?
    @State private var preparation: Task<Void, Never>?
    @State private var expanded = true
    @State private var details = false
    @State private var visible = false
    private var active: Bool { visible && isActive && workspace.canManageLocalModels }
    private var mode: LocalLinuxChatPreviewMode { .normalized(configuration.localLinuxChatPreviewMode) }

    var body: some View {
        Group {
            if (mode == .agentTools && tool != nil) || (mode == .userTerminal && terminal.jobID != nil) {
                VStack(alignment: .leading) {
                    HStack {
                        Button { expanded.toggle() } label: {
                            Label(mode.displayName, systemImage: expanded ? "chevron.down" : "chevron.right")
                        }
                        Spacer()
                        Button(NSLocalizedString("查看详情", comment: "")) { details = true }
                    }.buttonStyle(.borderless)
                    if expanded {
                        if mode == .agentTools, let tool {
                            Text(tool.displayTitle ?? tool.toolName).font(.caption).foregroundStyle(.secondary)
                            Text(tool.previewText).font(.caption.monospaced()).lineLimit(4).textSelection(.enabled)
                        } else {
                            ForEach(terminal.lines) { Text($0.displayText).font(.caption.monospaced()).lineLimit(1) }
                        }
                    }
                }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 460, alignment: .leading)
            }
        }
        .onAppear { visible = true; refresh() }
        .onDisappear { visible = false; stop() }
        .onChange(of: active) { _, value in if value { refresh() } else { stop() } }
        .onChange(of: configuration.localLinuxChatPreviewMode) { _, _ in refresh() }
        .onChange(of: colorScheme) { _, _ in refresh() }
        .onChange(of: workspace.currentSession?.id) { _, _ in details = false; tool = nil; refresh() }
        .onChange(of: workspace.linux.epoch) { _, _ in refresh() }
        .onReceive(workspace.$messages) { _ in prepareTool() }
        .sheet(isPresented: $details) {
            NavigationStack {
                Group {
                    if mode == .userTerminal {
                        MacLinuxTerminalView(isActive: active, runtime: workspace.linux, initialJobID: terminal.jobID)
                    } else if let tool {
                        Form {
                            LabeledContent(NSLocalizedString("工具", comment: ""), value: tool.displayTitle ?? tool.toolName)
                            Section(NSLocalizedString("参数", comment: "")) { Text(tool.arguments).font(.body.monospaced()).textSelection(.enabled) }
                            if let result = tool.result {
                                Section(NSLocalizedString("结果", comment: "")) { Text(result).font(.body.monospaced()).textSelection(.enabled) }
                            }
                        }.formStyle(.grouped)
                            .guideSettingsPageContext(id: "mac-tool-execution-preview", title: mode.displayName,
                                documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux")], isActive: active,
                                settings: [.readOnly("tool_name", label: NSLocalizedString("工具", comment: ""), value: { .string(tool.toolName) }),
                                           .readOnly("running", label: NSLocalizedString("运行中", comment: ""), value: { .bool(tool.state == .running) })])
                    }
                }
                .navigationTitle(mode.displayName)
                .toolbar { Button(NSLocalizedString("关闭", comment: "")) { details = false } }
            }.frame(minWidth: 560, minHeight: 400).modifier(MacGuideInspector())
        }
    }

    private func refresh() {
        terminal.stop()
        guard active else { return }
        if mode == .userTerminal { terminal.open(appearance: colorScheme == .dark ? .dark : .light) }
        prepareTool()
    }

    private func prepareTool() {
        preparation?.cancel()
        guard active, mode == .agentTools, let sessionID = workspace.currentSession?.id, let service = workspace.service else { tool = nil; return }
        preparation = Task {
            let value = await Task.detached(priority: .utility) { () -> AgentToolExecutionPreviewSnapshot? in
                guard Persistence.localAgentMode(sessionID: sessionID) == .agent else { return nil }
                var accumulator = AgentToolExecutionPreviewAccumulator()
                for message in service.messagesSnapshot(for: sessionID) { accumulator.append(message) }
                return accumulator.preferred
            }.value
            if !Task.isCancelled, active, workspace.currentSession?.id == sessionID { tool = value }
        }
    }

    private func stop() { preparation?.cancel(); terminal.stop(); tool = nil; details = false }
}
