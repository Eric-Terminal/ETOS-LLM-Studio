import ETOSCore
import SwiftUI

struct MacLinuxJobDetailView: View {
    let jobID: UUID
    let isActive: Bool
    @ObservedObject var runtime: MacLinuxModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacLinuxJobDetailModel()
    @StateObject private var actions = MacLinuxJobActionModel()
    @State private var visible = false
    @State private var cancellation: MacLinuxJobCancellation?
    private var active: Bool { visible && isActive && workspace.canManageLocalModels && !runtime.isSuspended }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "linux-job-detail", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("mac.shell.jobs.help", comment: ""), documentID: "macos-workspace",
                    isActive: isActive && workspace.canManageLocalModels && !runtime.isSuspended && cancellation == nil)
                Button(NSLocalizedString("刷新", comment: "")) { model.reload() }.disabled(model.isLoading)
            }
            if let details = model.details {
                Section(NSLocalizedString("状态", comment: "")) {
                    ForEach(details.fields) { field in LabeledContent(field.title, value: field.value).textSelection(.enabled) }
                }
                if !details.job.state.isTerminal {
                    Section {
                        if details.job.kind == .terminal {
                            NavigationLink {
                                MacLinuxTerminalView(isActive: isActive, runtime: runtime, initialJobID: jobID)
                            } label: { Label(NSLocalizedString("终端", comment: ""), systemImage: "terminal") }
                        }
                        Button(NSLocalizedString("停止任务", comment: ""), role: .destructive) {
                            cancellation = MacLinuxJobCancellation(action: .job(jobID))
                        }.disabled(actions.isWorking)
                        if let runID = details.job.runID {
                            Button(NSLocalizedString("停止此 Agent", comment: ""), role: .destructive) {
                                cancellation = MacLinuxJobCancellation(action: .agent(runID))
                            }.disabled(actions.isWorking)
                        }
                    }
                }
                if details.job.diagnosticID != nil {
                    NavigationLink {
                        MacLinuxDiagnosticView(jobID: jobID, isActive: isActive, runtime: runtime)
                    } label: { Label(NSLocalizedString("诊断详情", comment: ""), systemImage: "stethoscope") }
                }
                Section(NSLocalizedString("原始输出", comment: "")) {
                    Text(model.output.text.isEmpty ? NSLocalizedString("没有输出。", comment: "") : model.output.text)
                        .font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if let error = model.outputError { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
                    if !model.output.isComplete, model.output.nextCursor == nil {
                        Text(NSLocalizedString("输出尚未完整写入。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(NSLocalizedString("上一页", comment: "")) { model.previousPage() }.disabled(!model.canGoBack)
                        Spacer()
                        Text(String(format: NSLocalizedString("第 %lld 页", comment: ""), Int64(model.pageNumber))).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(NSLocalizedString("下一页", comment: "")) { model.nextPage() }.disabled(!model.canGoForward)
                    }.buttonStyle(.borderless)
                    Button(NSLocalizedString("复制本页输出", comment: "")) { model.copyOutput() }.disabled(model.output.text.isEmpty)
                }
            }
            if model.isLoading || actions.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = actions.error ?? model.error { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .formStyle(.grouped).navigationTitle(NSLocalizedString("任务详情", comment: ""))
        .disabled(!isActive || !workspace.canManageLocalModels || runtime.isSuspended)
        .onAppear { visible = true; open() }.onDisappear { visible = false; close(clearContent: false) }
        .onChange(of: active) { _, value in if value { open() } else { close(clearContent: visible) } }
        .onChange(of: runtime.epoch) { _, _ in close(); open() }
        .onChange(of: jobID) { _, _ in close(); open() }
        .onChange(of: configuration.appLanguage) { _, _ in if active { model.reload() } }
        .confirmationDialog(NSLocalizedString("停止任务", comment: ""), isPresented: Binding(
            get: { cancellation != nil }, set: { if !$0 { cancellation = nil } }
        ), titleVisibility: .visible, presenting: cancellation) { target in
            Button(target.action.title, role: .destructive) { if active { actions.execute(target) } }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { cancellation = nil }
        } message: { target in Text(target.action.confirmation) }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-job-\(jobID)-\(model.lease)-\(runtime.epoch)"), title: NSLocalizedString("任务详情", comment: ""),
            documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && cancellation == nil,
            settings: [
                .readOnly("job_id", label: NSLocalizedString("任务", comment: ""), value: { .string(jobID.uuidString) }),
                .readOnly("state", label: NSLocalizedString("状态", comment: ""), value: { .string(model.details?.job.state.rawValue ?? "") }),
                .readOnly("kind", label: NSLocalizedString("类型", comment: ""), value: { .string(model.details?.job.kind.rawValue ?? "") }),
                .readOnly("diagnostic_id", label: NSLocalizedString("诊断编号", comment: ""), value: { .string(model.diagnostic?.id.uuidString ?? "") }),
                .readOnly("page", label: NSLocalizedString("原始输出", comment: ""), value: { .int(model.pageNumber) }),
                .readOnly("manual_stop_only", label: NSLocalizedString("停止任务", comment: ""), value: { .bool(true) })
            ]
        )
    }

    private func open() { if active { model.open(jobID: jobID) } }
    private func close(clearContent: Bool = true) { cancellation = nil; model.leave(clearContent: clearContent); actions.invalidate() }
}

struct MacLinuxDiagnosticView: View {
    let jobID: UUID
    let isActive: Bool
    @ObservedObject var runtime: MacLinuxModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacLinuxJobDetailModel()
    @State private var visible = false
    private var active: Bool { visible && isActive && workspace.canManageLocalModels && !runtime.isSuspended }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "linux-diagnostic", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("mac.shell.jobs.help", comment: ""), documentID: "macos-workspace",
                    isActive: isActive && workspace.canManageLocalModels && !runtime.isSuspended)
                Button(NSLocalizedString("刷新", comment: "")) { model.reload() }.disabled(model.isLoading)
            }
            if let diagnostic = model.diagnostic {
                Section {
                    ForEach(diagnostic.fields) { field in LabeledContent(field.title, value: field.value).textSelection(.enabled) }
                }
                Section(NSLocalizedString("完整诊断", comment: "")) {
                    Text(diagnostic.json).font(.body.monospaced()).textSelection(.enabled)
                    Button(NSLocalizedString("复制诊断", comment: "")) { model.copyDiagnostic() }
                }
            } else if !model.isLoading, model.error == nil {
                Text(NSLocalizedString("暂无诊断记录。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
            if model.isLoading { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .formStyle(.grouped).navigationTitle(NSLocalizedString("诊断详情", comment: ""))
        .disabled(!isActive || !workspace.canManageLocalModels || runtime.isSuspended)
        .onAppear { visible = true; open() }.onDisappear { visible = false; model.leave(clearContent: false) }
        .onChange(of: active) { _, value in if value { open() } else { model.leave(clearContent: visible) } }
        .onChange(of: runtime.epoch) { _, _ in model.leave(); open() }
        .onChange(of: jobID) { _, _ in model.leave(); open() }
        .onChange(of: configuration.appLanguage) { _, _ in if active { model.reload() } }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-diagnostic-\(jobID)-\(model.lease)-\(runtime.epoch)"), title: NSLocalizedString("诊断详情", comment: ""),
            documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active,
            settings: [
                .readOnly("job_id", label: NSLocalizedString("任务", comment: ""), value: { .string(jobID.uuidString) }),
                .readOnly("diagnostic_id", label: NSLocalizedString("诊断编号", comment: ""), value: { .string(model.diagnostic?.id.uuidString ?? "") }),
                .readOnly("read_only", label: NSLocalizedString("完整诊断", comment: ""), value: { .bool(true) })
            ]
        )
    }

    private func open() { if active { model.open(jobID: jobID, includesOutput: false) } }
}
