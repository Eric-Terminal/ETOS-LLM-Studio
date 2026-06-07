// ============================================================================
// LocalDebugView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 反向探针调试界面 - 主动连接电脑端服务器
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

public struct LocalDebugView: View {
    @StateObject private var server = LocalDebugServer()
    @StateObject private var discovery = LocalDebugServerDiscovery()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingDocs = false
    @State private var showingLogs = false
    @State private var serverURL: String = ""
    @State private var pendingDiscoveredServer: LocalDebugDiscoveredServer?
    @State private var promptedDiscoveredServerIDs: Set<String> = []
    
    public init() {}
    
    public var body: some View {
        content
            .navigationTitle(NSLocalizedString("诊断", comment: ""))
            .navigationBarBackButtonHidden(server.isRunning)
            .sheet(isPresented: $showingDocs) {
                NavigationStack {
                    WatchDocumentationView()
                }
            }
            .sheet(isPresented: $showingLogs) {
                NavigationStack {
                    WatchDebugLogsView(server: server)
                }
            }
            .alert(
                NSLocalizedString("发现调试服务器", comment: ""),
                isPresented: discoveredServerAlertBinding
            ) {
                Button(NSLocalizedString("填入地址", comment: "")) {
                    if let candidate = pendingDiscoveredServer {
                        fillDiscoveredServer(candidate)
                    }
                    pendingDiscoveredServer = nil
                }
                Button(NSLocalizedString("稍后", comment: ""), role: .cancel) {
                    pendingDiscoveredServer = nil
                }
            } message: {
                discoveredServerAlertMessage
            }
            .onAppear {
                loadStoredServerURL()
                discovery.start()
            }
            .onDisappear {
                discovery.stop()
            }
            .onChange(of: discovery.discoveredServers) { _, candidates in
                promptForDiscoveredServerIfNeeded(candidates)
            }
            .onChange(of: server.isRunning) { _, isRunning in
                if isRunning {
                    discovery.stop()
                } else {
                    discovery.start()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active && server.isRunning {
                    disconnectServer()
                }
            }
    }

    private var content: some View {
        List {
            connectionStatusSection
            if !server.isRunning {
                connectionModeSection
                discoverySection
                serverAddressSection
            } else {
                connectedInfoSection
                debugLogsSection
            }
            pendingOpenAISection
            documentationSection
        }
    }

    private var connectionStatusSection: some View {
        Section {
            HStack {
                Circle()
                    .fill(server.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(server.connectionStatus)
                    .etFont(.caption)
                    .foregroundStyle(server.isRunning ? .green : .secondary)
            }

            if let error = server.errorMessage {
                Text(error)
                    .etFont(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private var connectionModeSection: some View {
        Section {
            Toggle(isOn: $server.useHTTP) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.useHTTP ? NSLocalizedString("HTTP 轮询", comment: "") : "WebSocket")
                        .etFont(.caption)
                    Text(server.useHTTP ? NSLocalizedString("稳定但较慢", comment: "") : NSLocalizedString("快速优先，失败自动回退 HTTP", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(NSLocalizedString("连接模式", comment: ""))
        }
    }

    private var discoverySection: some View {
        Section {
            discoveredServerRows
            Button {
                discovery.restart()
            } label: {
                Label(NSLocalizedString("重新扫描", comment: ""), systemImage: "arrow.clockwise")
                    .etFont(.caption)
            }
        } header: {
            Text(NSLocalizedString("自动发现", comment: ""))
        } footer: {
            Text(discoveryFooterText)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var discoveredServerRows: some View {
        if discoveredServerCandidates.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.blue)
                Text(discovery.isSearching ? NSLocalizedString("正在搜索", comment: "") : NSLocalizedString("未发现调试服务器", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(discoveredServerCandidates) { candidate in
                Button {
                    fillDiscoveredServer(candidate)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.name)
                            .etFont(.caption)
                        Text(candidate.connectionAddress(useHTTP: server.useHTTP))
                            .etFont(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var serverAddressSection: some View {
        Section {
            TextField(serverAddressPlaceholder, text: $serverURL.watchKeyboardNewlineBinding())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button(NSLocalizedString("连接", comment: "")) {
                connectToServer()
            }
            .foregroundStyle(.blue)
            .disabled(trimmedServerURL.isEmpty)
        } header: {
            Text(NSLocalizedString("服务器地址", comment: ""))
        }
    }

    private var connectedInfoSection: some View {
        Section(NSLocalizedString("连接信息", comment: "")) {
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("服务器", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                Text(server.serverURL)
                    .etFont(.caption.monospaced())
            }

            Button(NSLocalizedString("断开", comment: "")) {
                disconnectServer()
            }
            .foregroundStyle(.red)
        }
    }

    private var debugLogsSection: some View {
        Section {
            Button {
                showingLogs = true
            } label: {
                HStack {
                    Text(NSLocalizedString("调试日志", comment: ""))
                        .etFont(.caption)
                    Spacer()
                    Text("\(server.debugLogs.count)")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var pendingOpenAISection: some View {
        if hasPendingOpenAIRequest {
            Section {
                if let pending = server.pendingOpenAIRequest {
                    let modelName = pending.model ?? NSLocalizedString("未知", comment: "")
                    Text(String(format: NSLocalizedString("请求详情：模型 %@ · 消息 %d", comment: ""), modelName, pending.messageCount))
                        .etFont(.caption2)
                    Text(formatPendingTime(pending.receivedAt))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("保存日志", comment: "")) {
                        server.resolvePendingOpenAIRequest(save: true)
                    }
                    .etFont(.caption)
                    Button(NSLocalizedString("忽略", comment: "")) {
                        server.resolvePendingOpenAIRequest(save: false)
                    }
                    .etFont(.caption)
                }
            } header: {
                Text(NSLocalizedString("API 流量分析", comment: ""))
            } footer: {
                pendingOpenAIFooter
            }
        }
    }

    @ViewBuilder
    private var pendingOpenAIFooter: some View {
        if server.pendingOpenAIQueueCount > 1 {
            Text(String(format: NSLocalizedString("剩余 %d 条记录", comment: ""), server.pendingOpenAIQueueCount - 1))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var documentationSection: some View {
        Section {
            Button {
                showingDocs = true
            } label: {
                Label(NSLocalizedString("使用说明", comment: ""), systemImage: "book")
                    .etFont(.caption)
            }
        } footer: {
            Text(NSLocalizedString("远程诊断模式 · 主动连接调试端", comment: ""))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var discoveredServerCandidates: [LocalDebugDiscoveredServer] {
        Array(discovery.discoveredServers.prefix(3))
    }

    private var discoveryFooterText: String {
        discovery.errorMessage ?? NSLocalizedString("发现电脑端后可一键填入地址。", comment: "")
    }

    private var serverAddressPlaceholder: String {
        server.useHTTP ? "192.168.1.100:7654" : "192.168.1.100:8765"
    }

    private var hasPendingOpenAIRequest: Bool {
        server.isRunning && (server.pendingOpenAIRequest != nil || server.pendingOpenAIQueueCount > 0)
    }

    private var discoveredServerAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDiscoveredServer != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDiscoveredServer = nil
                }
            }
        )
    }

    @ViewBuilder
    private var discoveredServerAlertMessage: some View {
        if let candidate = pendingDiscoveredServer {
            Text(String(format: NSLocalizedString("是否填入 %@？", comment: ""), candidate.connectionAddress(useHTTP: server.useHTTP)))
        }
    }

    private var trimmedServerURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func connectToServer() {
        let address = trimmedServerURL
        guard !address.isEmpty else { return }
        AppConfigStore.persistSynchronously(.text(address), for: .localDebugLastServerAddress, quickSync: false)
        server.connect(to: address)
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
    }
    
    private func disconnectServer() {
        server.disconnect()
        discovery.start()
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = false
    }

    private func loadStoredServerURL() {
        guard trimmedServerURL.isEmpty else { return }
        let storedAddress = AppConfigStore.textValue(for: .localDebugLastServerAddress)
        if !storedAddress.isEmpty {
            serverURL = storedAddress
        }
    }

    private func fillDiscoveredServer(_ candidate: LocalDebugDiscoveredServer) {
        serverURL = candidate.connectionAddress(useHTTP: server.useHTTP)
    }

    private func promptForDiscoveredServerIfNeeded(_ candidates: [LocalDebugDiscoveredServer]) {
        guard !server.isRunning,
              trimmedServerURL.isEmpty,
              pendingDiscoveredServer == nil,
              let candidate = candidates.first(where: { !promptedDiscoveredServerIDs.contains($0.id) }) else {
            return
        }
        promptedDiscoveredServerIDs.insert(candidate.id)
        pendingDiscoveredServer = candidate
    }

    private func formatPendingTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MdHm")
        return formatter.string(from: date)
    }
}

// MARK: - 文档视图 (watchOS)

private struct WatchDocumentationView: View {
    @Environment(\.dismiss) private var dismiss
    private let debugToolReleaseURL = URL(string: "https://github.com/Eric-Terminal/ETOS-LLM-Studio/releases/latest")!
    
    var body: some View {
        List {
            Section(NSLocalizedString("工作原理", comment: "")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("WebSocket 模式", comment: ""))
                        .etFont(.caption)
                        .fontWeight(.semibold)
                    Text(NSLocalizedString("设备主动连接电脑端服务器（端口 8765），实时接收命令", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    
                    Text(NSLocalizedString("HTTP 轮询模式", comment: ""))
                        .etFont(.caption)
                        .fontWeight(.semibold)
                        .padding(.top, 4)
                    Text(NSLocalizedString("设备高频请求服务器（端口 7654），获取待执行命令", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section(NSLocalizedString("启动步骤", comment: "")) {
                VStack(alignment: .leading, spacing: 8) {
                    StepItem(num: 1, text: "电脑端下载并运行:")
                    Text(NSLocalizedString("在 GitHub Release 下载最新调试工具（Go 版）", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading)
                    Link(destination: debugToolReleaseURL) {
                        Label(NSLocalizedString("前往下载页面", comment: ""), systemImage: "arrow.up.right.square")
                            .etFont(.caption2)
                    }
                    .padding(.leading)
                    
                    StepItem(num: 2, text: "自动发现或记下 IP")
                    
                    StepItem(num: 3, text: "填入地址并连接")
                    
                    StepItem(num: 4, text: "电脑端菜单操作文件")
                }
            }
            
            Section(NSLocalizedString("功能", comment: "")) {
                FeatureItem(icon: "folder", name: "文件管理", desc: "管理应用内数据")
                FeatureItem(icon: "tray.and.arrow.down", name: "流量分析", desc: "API 请求日志记录")
                FeatureItem(icon: "menucard", name: "远程控制", desc: "通过调试端辅助操作")
            }
            
            Section(NSLocalizedString("API 代理", comment: "")) {
                Text(NSLocalizedString("设置 API Base URL 为:", comment: ""))
                    .etFont(.caption2)
                Text(NSLocalizedString("http://电脑IP:8080", comment: ""))
                    .etFont(.system(size: 10).monospaced())
                    .foregroundStyle(.blue)
                Text(NSLocalizedString("请求将重定向至调试端进行记录。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("使用说明", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StepItem: View {
    let num: Int
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(num)")
                .etFont(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(.blue))
            Text(NSLocalizedString(text, comment: "本地调试步骤文本"))
                .etFont(.caption2)
        }
    }
}

private struct FeatureItem: View {
    let icon: String
    let name: String
    let desc: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .etFont(.title3)
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString(name, comment: "本地调试功能标题"))
                    .etFont(.caption.weight(.medium))
                Text(NSLocalizedString(desc, comment: "本地调试功能说明"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 调试日志视图 (watchOS)

private struct WatchDebugLogsView: View {
    @ObservedObject var server: LocalDebugServer
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        List {
            if server.debugLogs.isEmpty {
                Text(NSLocalizedString("暂无日志", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(server.debugLogs) { log in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: iconForType(log.type))
                                .foregroundStyle(colorForType(log.type))
                                .etFont(.caption2)
                            Text(log.message)
                                .etFont(.system(size: 10, design: .monospaced))
                                .lineLimit(2)
                        }
                        Text(formatTime(log.timestamp))
                            .etFont(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("日志", comment: ""))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(NSLocalizedString("清空", comment: "")) {
                    server.clearLogs()
                }
                .etFont(.caption2)
            }
        }
    }
    
    private func iconForType(_ type: LocalDebugServer.DebugLogEntry.LogType) -> String {
        switch type {
        case .info: return "info.circle"
        case .send: return "arrow.up"
        case .receive: return "arrow.down"
        case .error: return "xmark.circle"
        case .heartbeat: return "heart.fill"
        @unknown default: return "questionmark.circle"
        }
    }
    
    private func colorForType(_ type: LocalDebugServer.DebugLogEntry.LogType) -> Color {
        switch type {
        case .info: return .blue
        case .send: return .green
        case .receive: return .orange
        case .error: return .red
        case .heartbeat: return .pink
        @unknown default: return .gray
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

#Preview {
    NavigationView {
        LocalDebugView()
    }
}
