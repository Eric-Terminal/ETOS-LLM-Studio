import ETOSCore
import SwiftUI

@MainActor
struct MacRemoteAccessView: View {
    let isActive: Bool
    @ObservedObject var model: MacRemoteAccessModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    @State private var confirmation: MacRemoteCaptureConfirmation?
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "remote-access", title: NSLocalizedString("远程文件访问", comment: ""),
                    details: NSLocalizedString("Mac 远程访问说明", comment: ""), documentID: "remote-file-access", isActive: available)
                LabeledContent(NSLocalizedString("状态", comment: ""), value: model.server.isRunning
                    ? NSLocalizedString("已连接", comment: "") : model.connectionRequested
                    ? NSLocalizedString("等待连接...", comment: "") : NSLocalizedString("未连接", comment: ""))
                if model.isLoading || model.isStopping || model.server.isProcessingCommand {
                    ProgressView(NSLocalizedString("处理中…", comment: ""))
                }
                if let error = model.error ?? model.server.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if !model.connectionRequested {
                Section(NSLocalizedString("连接配置", comment: "")) {
                    Toggle(NSLocalizedString("HTTP 轮询", comment: ""), isOn: Binding(get: { model.useHTTP }, set: model.setHTTP))
                    TextField(NSLocalizedString("服务器地址", comment: ""), text: $model.address).autocorrectionDisabled()
                    Button(NSLocalizedString("连接", comment: ""), action: model.connect).disabled(!model.canConnect)
                }.disabled(!model.canEdit)
                Section {
                    if model.discovery.discoveredServers.isEmpty {
                        Text(model.discovery.isSearching ? NSLocalizedString("正在搜索局域网调试服务器", comment: "") : NSLocalizedString("未发现调试服务器", comment: ""))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(model.discovery.discoveredServers) { candidate in
                        Button { model.fill(candidate) } label: {
                            VStack(alignment: .leading) {
                                Text(candidate.name)
                                Text(candidate.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                    Button(NSLocalizedString("重新扫描", comment: ""), action: model.scan)
                    if let error = model.discovery.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text(NSLocalizedString("自动发现", comment: "")) }
                footer: {
                    Text(NSLocalizedString("发现电脑端调试工具后，可一键填入服务器地址。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }.disabled(!model.canEdit)
            } else {
                Section {
                    LabeledContent(NSLocalizedString("服务器", comment: ""), value: model.server.serverURL).textSelection(.enabled)
                    LabeledContent(NSLocalizedString("模式", comment: ""), value: model.useHTTP ? NSLocalizedString("HTTP 轮询", comment: "") : NSLocalizedString("WebSocket", comment: ""))
                    Button(NSLocalizedString("断开", comment: ""), role: .destructive, action: model.disconnect).disabled(model.isStopping)
                } header: { Text(NSLocalizedString("连接信息", comment: "")) }
                footer: {
                    Text(NSLocalizedString("关闭此页后连接仍会保留。锁定应用、备份、恢复或退出时会断开。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                NavigationLink {
                    MacRemoteAccessLogsView(isActive: isActive, model: model)
                } label: { Label(NSLocalizedString("调试日志", comment: ""), systemImage: "doc.text") }
            }
            if let capture = model.presentation?.capture {
                Section {
                    Text(capture.summary)
                    Text(capture.time).font(.caption).foregroundStyle(.secondary)
                    Button(NSLocalizedString("保存日志", comment: "")) { confirm(capture, save: true) }
                    Button(NSLocalizedString("忽略", comment: "")) { confirm(capture, save: false) }
                } header: { Text(NSLocalizedString("API 流量分析", comment: "")) }
                footer: {
                    Text(String(format: NSLocalizedString("队列中还有 %d 条记录", comment: ""), max(0, model.server.pendingOpenAIQueueCount - 1)))
                        .font(.footnote).foregroundStyle(.secondary)
                }.disabled(model.server.isProcessingCommand || model.isStopping)
            }
        }
        .formStyle(.grouped).navigationTitle(NSLocalizedString("远程文件访问", comment: ""))
        .disabled(!available)
        .onAppear { visible = true; model.setVisible(available) }
        .onDisappear { visible = false; model.setVisible(false); confirmation = nil }
        .onChange(of: available) { _, value in model.setVisible(visible && value); if !value { confirmation = nil } }
        .onChange(of: model.epoch) { _, _ in confirmation = nil }
        .onChange(of: configuration.appLanguage) { _, _ in confirmation = nil; model.refreshPresentation() }
        .sheet(item: $confirmation) { target in MacRemoteCaptureConfirmationView(target: target, isActive: available, model: model) }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-remote-access-\(model.epoch)-\(model.canEdit)-\(configuration.appLanguage)"),
            title: NSLocalizedString("远程文件访问", comment: ""), documents: Self.documents,
            isActive: available && visible && confirmation == nil, settings: guideSettings)
    }

    static var documents: [GuideDocumentReference] {
        [GuideDocumentReference(id: "remote-file-access", title: NSLocalizedString("远程文件访问", comment: ""))]
    }

    private var guideSettings: [GuidePageSetting] {
        let status: [GuidePageSetting] = [
            .readOnly("connected", label: NSLocalizedString("已连接", comment: ""), value: { .bool(model.server.isRunning) }),
            .readOnly("processing", label: NSLocalizedString("处理中…", comment: ""), value: { .bool(model.server.isProcessingCommand || model.isStopping) }),
            .readOnly("capture_count", label: NSLocalizedString("API 流量分析", comment: ""), value: { .int(model.server.pendingOpenAIQueueCount) }),
            .readOnly("log_count", label: NSLocalizedString("调试日志", comment: ""), value: { .int(model.presentation?.logs.count ?? 0) }),
            .readOnly("http_mode", label: NSLocalizedString("HTTP 轮询", comment: ""), value: { .bool(model.useHTTP) }),
            .readOnly("address_configured", label: NSLocalizedString("服务器地址", comment: ""), value: { .bool(!model.address.isEmpty) }),
            .readOnly("save_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("connection_draft_native_connect_required") })
        ]
        guard model.canEdit else { return status }
        return status + [
            .writeOnlyString("address_draft", label: NSLocalizedString("服务器地址", comment: ""),
                isConfigured: { !model.address.isEmpty }, set: { if available && model.canEdit { model.address = $0 } }),
            .bool("http_draft", label: NSLocalizedString("HTTP 轮询", comment: ""),
                get: { model.useHTTP }, set: { if available { model.setHTTP($0) } })
        ]
    }

    private func confirm(_ capture: MacRemoteAccessPresentation.Capture, save: Bool) {
        guard available, !model.isStopping, model.server.pendingOpenAIRequest?.id == capture.id else { return }
        confirmation = MacRemoteCaptureConfirmation(capture: capture, save: save, epoch: model.epoch)
    }
}

@MainActor
private struct MacRemoteAccessLogsView: View {
    let isActive: Bool
    @ObservedObject var model: MacRemoteAccessModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended }

    var body: some View {
        List {
            ForEach(model.presentation?.logs ?? []) { row in
                VStack(alignment: .leading) {
                    Text(row.time).font(.caption).foregroundStyle(.secondary)
                    Text(row.message).font(.body.monospaced()).foregroundStyle(row.isError ? Color.red : Color.primary).textSelection(.enabled)
                }
            }
        }
        .navigationTitle(NSLocalizedString("调试日志", comment: ""))
        .toolbar { Button(NSLocalizedString("清空日志", comment: "")) { if available { model.server.clearLogs() } }.disabled(!available) }
        .onAppear { visible = true; model.refreshPresentation() }.onDisappear { visible = false }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-remote-logs-\(model.epoch)"),
            title: NSLocalizedString("调试日志", comment: ""), documents: MacRemoteAccessView.documents,
            isActive: available && visible, settings: [
                .readOnly("log_count", label: NSLocalizedString("调试日志", comment: ""), value: { .int(model.presentation?.logs.count ?? 0) })
            ])
    }
}

private struct MacRemoteCaptureConfirmation: Identifiable {
    let id = UUID()
    let capture: MacRemoteAccessPresentation.Capture
    let save: Bool
    let epoch: UUID
}

@MainActor
private struct MacRemoteCaptureConfirmationView: View {
    let target: MacRemoteCaptureConfirmation
    let isActive: Bool
    @ObservedObject var model: MacRemoteAccessModel
    @Environment(\.dismiss) private var dismiss
    private var available: Bool { isActive && !model.isSuspended && !model.isStopping && target.epoch == model.epoch && target.capture.id == model.server.pendingOpenAIRequest?.id }
    private var title: String { target.save ? NSLocalizedString("保存日志", comment: "") : NSLocalizedString("忽略", comment: "") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(target.capture.summary)
                    Text(target.capture.time).font(.caption).foregroundStyle(.secondary)
                } footer: {
                    Text(target.save ? NSLocalizedString("捕获请求只在本机保存为会话，不会发送给模型。", comment: "")
                         : NSLocalizedString("确认后将从待处理队列移除，无法撤销。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(title) { model.resolveCapture(id: target.capture.id, save: target.save, expectedEpoch: target.epoch); dismiss() }.disabled(!available)
                    }
                }
                .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-remote-capture-\(target.id)"), title: title,
                    documents: MacRemoteAccessView.documents, isActive: available, settings: [
                        .readOnly("message_count", label: NSLocalizedString("消息数量", comment: ""), value: { .int(target.capture.messageCount) }),
                        .readOnly("save_to_history", label: NSLocalizedString("保存日志", comment: ""), value: { .bool(target.save) })
                    ])
        }.frame(minWidth: 440, minHeight: 240)
    }
}
