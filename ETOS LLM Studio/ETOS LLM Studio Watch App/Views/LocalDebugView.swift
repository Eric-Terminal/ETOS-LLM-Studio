// ============================================================================
// LocalDebugView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 反向探针调试界面 - 主动连接电脑端服务器
// ============================================================================

import SwiftUI
import Foundation
import Shared

public struct LocalDebugView: View {
    @StateObject private var server = LocalDebugServer()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingDocs = false
    @State private var showingLogs = false
    @State private var serverURL: String = ""
    
    public init() {}
    
    public var body: some View {
        List {
            // 连接状态
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
            
            // 连接配置
            if !server.isRunning {
                Section(header: Text("连接模式")) {
                    Toggle(isOn: $server.useHTTP) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.useHTTP ? "HTTP 轮询" : "WebSocket")
                                .etFont(.caption)
                            Text(server.useHTTP ? "稳定但较慢" : "快速优先，失败自动回退 HTTP")
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Section(header: Text("服务器地址")) {
                    TextField(server.useHTTP ? "192.168.1.100:7654" : "192.168.1.100:8765", text: $serverURL.watchKeyboardNewlineBinding())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("连接") {
                        connectToServer()
                    }
                    .foregroundStyle(.blue)
                    .disabled(serverURL.isEmpty)
                }
            } else {
                Section("连接信息") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("服务器")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                        Text(server.serverURL)
                            .etFont(.caption.monospaced())
                    }
                    
                    Button("断开") {
                        disconnectServer()
                    }
                    .foregroundStyle(.red)
                }
                
                // 调试日志
                Section {
                    Button {
                        showingLogs = true
                    } label: {
                        HStack {
                            Text("调试日志")
                                .etFont(.caption)
                            Spacer()
                            Text("\(server.debugLogs.count)")
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if server.isRunning, server.pendingOpenAIRequest != nil || server.pendingOpenAIQueueCount > 0 {
                Section {
                    if let pending = server.pendingOpenAIRequest {
                        let modelName = pending.model ?? NSLocalizedString("未知", comment: "")
                        Text(String(format: NSLocalizedString("请求详情：模型 %@ · 消息 %d", comment: ""), modelName, pending.messageCount))
                            .etFont(.caption2)
                        Text(formatPendingTime(pending.receivedAt))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                        Button("保存日志") {
                            server.resolvePendingOpenAIRequest(save: true)
                        }
                        .etFont(.caption)
                        Button("忽略") {
                            server.resolvePendingOpenAIRequest(save: false)
                        }
                        .etFont(.caption)
                    }
                } header: {
                    Text("API 流量分析")
                } footer: {
                    if server.pendingOpenAIQueueCount > 1 {
                        Text(String(format: NSLocalizedString("剩余 %d 条记录", comment: ""), server.pendingOpenAIQueueCount - 1))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // 文档
            Section {
                Button {
                    showingDocs = true
                } label: {
                    Label("使用说明", systemImage: "book")
                        .etFont(.caption)
                }
            } footer: {
                Text("远程诊断模式 · 主动连接调试端")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("诊断")
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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active && server.isRunning {
                disconnectServer()
            }
        }
    }
    
    private func connectToServer() {
        server.connect(to: serverURL)
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
    }
    
    private func disconnectServer() {
        server.disconnect()
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = false
    }

    private func formatPendingTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - 文档视图 (watchOS)

private struct WatchDocumentationView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        List {
            Section("工作原理") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WebSocket 模式")
                        .etFont(.caption)
                        .fontWeight(.semibold)
                    Text("设备主动连接电脑端服务器（端口 8765），实时接收命令")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    
                    Text("HTTP 轮询模式")
                        .etFont(.caption)
                        .fontWeight(.semibold)
                        .padding(.top, 4)
                    Text("设备每秒向服务器（端口 7654）请求一次，获取待执行命令")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("启动步骤") {
                VStack(alignment: .leading, spacing: 8) {
                    StepItem(num: 1, text: "电脑端下载并运行:")
                    Text("https://raw.githubusercontent.com/Eric-Terminal/ETOS-LLM-Studio/main/docs/debug-tools/debug_server.py")
                        .etFont(.system(size: 9).monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.leading)
                    
                    StepItem(num: 2, text: "记下显示的 IP 地址")
                    
                    StepItem(num: 3, text: "在本界面输入 IP 并连接")
                    
                    StepItem(num: 4, text: "电脑端菜单操作文件")
                }
            }
            
            Section("功能") {
                FeatureItem(icon: "folder", name: "文件管理", desc: "管理应用内数据")
                FeatureItem(icon: "tray.and.arrow.down", name: "流量分析", desc: "API 请求日志记录")
                FeatureItem(icon: "menucard", name: "远程控制", desc: "通过调试端辅助操作")
            }
            
            Section("API 代理") {
                Text("设置 API Base URL 为:")
                    .etFont(.caption2)
                Text("http://电脑IP:8080")
                    .etFont(.system(size: 10).monospaced())
                    .foregroundStyle(.blue)
                Text("请求将重定向至调试端进行记录。")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("使用说明")
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
            Text(text)
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
                Text(name)
                    .etFont(.caption.weight(.medium))
                Text(desc)
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
                Text("暂无日志")
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
        .navigationTitle("日志")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空") {
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
