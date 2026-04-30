// ============================================================================
// LocalDebugView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 反向探针调试界面 - 主动连接电脑端服务器
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct LocalDebugView: View {
    @StateObject private var server = LocalDebugServer()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAPIDoc = false
    @State private var serverURL: String = ""
    @State private var showLogs = false
    
    var body: some View {
        List {
            // 连接状态
            Section {
                HStack {
                    Image(systemName: server.isRunning ? "circle.fill" : "circle")
                        .foregroundStyle(server.isRunning ? .green : .secondary)
                        .imageScale(.small)
                    Text(server.connectionStatus)
                        .foregroundStyle(server.isRunning ? .green : .secondary)
                }
                
                if let error = server.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .etFont(.footnote)
                }
            } header: {
                Text(NSLocalizedString("状态", comment: ""))
            }
            
            // 连接配置
            if !server.isRunning {
                Section(header: Text(NSLocalizedString("连接模式", comment: ""))) {
                    Toggle(isOn: $server.useHTTP) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.useHTTP ? NSLocalizedString("HTTP 轮询", comment: "") : "WebSocket")
                                .etFont(.body)
                            Text(server.useHTTP ? NSLocalizedString("稳定但较慢，适合真机", comment: "") : NSLocalizedString("快速优先，失败自动回退 HTTP", comment: ""))
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Section {
                    TextField(NSLocalizedString("输入地址", comment: ""), text: $serverURL, prompt: Text(server.useHTTP ? "192.168.1.100:7654" : "192.168.1.100:8765"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .etFont(.body.monospaced())
                    
                    Button(NSLocalizedString("连接", comment: "")) {
                        connectToServer()
                    }
                    .disabled(serverURL.isEmpty)
                } header: {
                    Text(NSLocalizedString("服务器地址", comment: ""))
                } footer: {
                    Text(server.useHTTP ? NSLocalizedString("HTTP 默认端口: 7654", comment: "") : NSLocalizedString("WebSocket 默认端口: 8765（可用 host:wsPort:httpPort 显式指定回退端口）", comment: ""))
                }
            } else {
                Section(NSLocalizedString("连接信息", comment: "")) {
                    LabeledContent(NSLocalizedString("服务器", comment: "")) {
                        Text(server.serverURL)
                            .etFont(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    
                    LabeledContent(NSLocalizedString("模式", comment: "")) {
                        Text(server.useHTTP ? NSLocalizedString("HTTP 轮询", comment: "") : "WebSocket")
                    }
                    
                    Button(NSLocalizedString("断开", comment: "")) {
                        disconnectServer()
                    }
                    .tint(.red)
                }
                
                // 调试日志
                Section {
                    Button {
                        showLogs = true
                    } label: {
                        HStack {
                            Label(NSLocalizedString("调试日志", comment: ""), systemImage: "doc.text")
                            Spacer()
                            Text("\(server.debugLogs.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("调试", comment: ""))
                }
            }

            if server.isRunning, server.pendingOpenAIRequest != nil || server.pendingOpenAIQueueCount > 0 {
                Section {
                    if let pending = server.pendingOpenAIRequest {
                        let modelName = pending.model ?? NSLocalizedString("未知", comment: "")
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(format: NSLocalizedString("请求详情：模型 %@ · 消息数 %d", comment: ""), modelName, pending.messageCount))
                                .etFont(.subheadline)
                            Text(formatPendingTime(pending.receivedAt))
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(NSLocalizedString("保存日志", comment: "")) {
                                server.resolvePendingOpenAIRequest(save: true)
                            }
                            .buttonStyle(.borderedProminent)
                            
                            Button(NSLocalizedString("忽略", comment: "")) {
                                server.resolvePendingOpenAIRequest(save: false)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("API 流量分析", comment: ""))
                } footer: {
                    if server.pendingOpenAIQueueCount > 1 {
                        Text(String(format: NSLocalizedString("队列中还有 %d 条记录", comment: ""), server.pendingOpenAIQueueCount - 1))
                    }
                }
            }
            
            // 使用说明
            Section(header: Text(NSLocalizedString("文档", comment: "")), footer: Text(NSLocalizedString("远程诊断模式 · 主动连接调试端", comment: ""))) {
                Button {
                    showAPIDoc = true
                } label: {
                    Label(NSLocalizedString("使用说明", comment: ""), systemImage: "book")
                }
            }
            
            // 安全提示
            Section(header: Text(NSLocalizedString("提示", comment: ""))) {
                Label(NSLocalizedString("仅在可信网络中使用", comment: ""), systemImage: "wifi")
                Label(NSLocalizedString("用完后请及时断开连接", comment: ""), systemImage: "hand.raised")
            }
            .foregroundStyle(.secondary)
            .etFont(.footnote)
        }
        .navigationTitle(NSLocalizedString("高级诊断", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(server.isRunning)
        .interactiveDismissDisabled(server.isRunning)
        .sheet(isPresented: $showAPIDoc) {
            NavigationStack {
                DocumentationView()
            }
        }
        .sheet(isPresented: $showLogs) {
            NavigationStack {
                DebugLogsView(server: server)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active && server.isRunning {
                disconnectServer()
            }
        }
    }
    
    private func connectToServer() {
        server.connect(to: serverURL)
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    private func disconnectServer() {
        server.disconnect()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func formatPendingTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - 调试日志视图

private struct DebugLogsView: View {
    @ObservedObject var server: LocalDebugServer
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        List {
            if server.debugLogs.isEmpty {
                ContentUnavailableView(NSLocalizedString("暂无日志", comment: ""), systemImage: "doc.text", description: Text(NSLocalizedString("连接后会显示调试信息", comment: "")))
            } else {
                ForEach(server.debugLogs) { log in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: iconForType(log.type))
                            .foregroundStyle(colorForType(log.type))
                            .frame(width: 20)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(log.message)
                                .etFont(.system(.caption, design: .monospaced))
                            Text(formatTime(log.timestamp))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("调试日志", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(NSLocalizedString("清空", comment: "")) {
                    server.clearLogs()
                }
                .disabled(server.debugLogs.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(NSLocalizedString("完成", comment: "")) {
                    dismiss()
                }
            }
        }
    }
    
    private func iconForType(_ type: LocalDebugServer.DebugLogEntry.LogType) -> String {
        switch type {
        case .info: return "info.circle"
        case .send: return "arrow.up.circle"
        case .receive: return "arrow.down.circle"
        case .error: return "exclamationmark.circle"
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
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

// MARK: - 文档视图

private struct DocumentationView: View {
    @Environment(\.dismiss) private var dismiss
    private let debugToolReleaseURL = URL(string: "https://github.com/Eric-Terminal/ETOS-LLM-Studio/releases/latest")!
    
    var body: some View {
        List {
            Section(NSLocalizedString("工作原理", comment: "")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone")
                            .etFont(.title2)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Image(systemName: "desktopcomputer")
                            .etFont(.title2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    
                    Text(NSLocalizedString("设备主动连接电脑端 WebSocket 服务器，接收命令并执行文件操作。", comment: ""))
                        .etFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section(NSLocalizedString("启动步骤", comment: "")) {
                StepRow(
                    number: 1,
                    title: "电脑端下载并运行",
                    detail: "在 GitHub Release 下载最新调试工具（Go 版）",
                    linkTitle: "前往下载页面",
                    linkURL: debugToolReleaseURL
                )
                StepRow(number: 2, title: "记录 IP", detail: "工具会显示电脑的局域网 IP 地址")
                StepRow(number: 3, title: "输入并连接", detail: "在本界面输入 IP 地址和端口（默认 8765）")
                StepRow(number: 4, title: "开始操作", detail: "电脑端会显示交互式菜单，选择操作即可")
            }
            
            Section(NSLocalizedString("功能", comment: "")) {
                FeatureRow(icon: "folder", title: "文件管理", description: "管理应用沙盒内的文件和目录")
                FeatureRow(icon: "tray.and.arrow.down", title: "API 分析", description: "查看并分析 API 请求日志")
                FeatureRow(icon: "menucard", title: "远程控制", description: "通过电脑端菜单进行辅助操作")
            }
            
            Section(NSLocalizedString("API 代理设置", comment: "")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("将 API Base URL 设置为：", comment: ""))
                        .etFont(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text(NSLocalizedString("http://电脑IP:8080", comment: ""))
                        .etFont(.body.monospaced())
                        .foregroundStyle(.blue)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    
                    Text(NSLocalizedString("请求将被重定向到调试端进行记录和分析。", comment: ""))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section(NSLocalizedString("特性", comment: "")) {
                Label(NSLocalizedString("局域网直连，无中间服务器", comment: ""), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label(NSLocalizedString("实时日志流", comment: ""), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label(NSLocalizedString("可视化菜单操作", comment: ""), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .navigationTitle(NSLocalizedString("使用说明", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(NSLocalizedString("完成", comment: "")) {
                    dismiss()
                }
            }
        }
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let detail: String
    let linkTitle: String?
    let linkURL: URL?
    
    init(number: Int, title: String, detail: String, linkTitle: String? = nil, linkURL: URL? = nil) {
        self.number = number
        self.title = title
        self.detail = detail
        self.linkTitle = linkTitle
        self.linkURL = linkURL
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .etFont(.headline)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.blue))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString(title, comment: "本地调试步骤标题"))
                    .etFont(.headline)
                Text(NSLocalizedString(detail, comment: "本地调试步骤详情"))
                    .etFont(.subheadline)
                    .foregroundStyle(.secondary)
                
                if let linkTitle, let linkURL {
                    Link(destination: linkURL) {
                        Label(NSLocalizedString(linkTitle, comment: "本地调试步骤链接"), systemImage: "arrow.up.right.square")
                            .etFont(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .etFont(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString(title, comment: "本地调试功能标题"))
                    .etFont(.headline)
                Text(NSLocalizedString(description, comment: "本地调试功能说明"))
                    .etFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationView {
        LocalDebugView()
    }
}
