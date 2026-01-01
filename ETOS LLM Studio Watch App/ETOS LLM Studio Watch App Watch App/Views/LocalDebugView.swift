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
                        .font(.caption)
                        .foregroundStyle(server.isRunning ? .green : .secondary)
                }
                
                if let error = server.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            
            // 连接配置
            if !server.isRunning {
                Section(header: Text("服务器地址")) {
                    TextField("192.168.1.100:8765", text: $serverURL)
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
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(server.serverURL)
                            .font(.caption.monospaced())
                    }
                    
                    Button("断开") {
                        disconnectServer()
                    }
                    .foregroundStyle(.red)
                }
            }

            if server.isRunning, server.pendingOpenAIRequest != nil || server.pendingOpenAIQueueCount > 0 {
                Section {
                    if let pending = server.pendingOpenAIRequest {
                        let modelName = pending.model ?? NSLocalizedString("未知", comment: "")
                        Text(String(format: NSLocalizedString("模型 %@ · 消息 %d", comment: ""), modelName, pending.messageCount))
                            .font(.caption2)
                        Text(formatPendingTime(pending.receivedAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("保存到本地") {
                            server.resolvePendingOpenAIRequest(save: true)
                        }
                        .font(.caption)
                        Button("忽略") {
                            server.resolvePendingOpenAIRequest(save: false)
                        }
                        .font(.caption)
                    }
                } header: {
                    Text("OpenAI 捕获")
                } footer: {
                    if server.pendingOpenAIQueueCount > 1 {
                        Text(String(format: NSLocalizedString("剩余 %d 条", comment: ""), server.pendingOpenAIQueueCount - 1))
                            .font(.caption2)
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
                        .font(.caption)
                }
            } footer: {
                Text("反向探针模式 · 主动连接电脑")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("调试")
        .navigationBarBackButtonHidden(server.isRunning)
        .sheet(isPresented: $showingDocs) {
            NavigationStack {
                WatchDocumentationView()
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
                Text("设备主动连接电脑端 WebSocket 服务器，接收命令并执行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Section("启动步骤") {
                VStack(alignment: .leading, spacing: 8) {
                    StepItem(num: 1, text: "电脑端运行:")
                    Text("cd docs/debug-tools\n./start_debug_server.sh")
                        .font(.system(size: 9).monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.leading)
                    
                    StepItem(num: 2, text: "记下显示的 IP 地址")
                    
                    StepItem(num: 3, text: "在本界面输入 IP 并连接")
                    
                    StepItem(num: 4, text: "电脑端菜单操作文件")
                }
            }
            
            Section("功能") {
                FeatureItem(icon: "📂", name: "文件管理", desc: "列出、下载、上传、删除")
                FeatureItem(icon: "📥", name: "OpenAI 捕获", desc: "转发请求到设备确认")
                FeatureItem(icon: "🎯", name: "菜单操作", desc: "无需输入命令")
            }
            
            Section("OpenAI 代理") {
                Text("设置 API Base URL 为:")
                    .font(.caption2)
                Text("http://电脑IP:8080")
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.blue)
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
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(.blue))
            Text(text)
                .font(.caption2)
        }
    }
}

private struct FeatureItem: View {
    let icon: String
    let name: String
    let desc: String
    
    var body: some View {
        HStack(spacing: 8) {
            Text(icon)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.caption.weight(.medium))
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationView {
        LocalDebugView()
    }
}
