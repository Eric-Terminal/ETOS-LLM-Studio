// ============================================================================
// LocalDebugView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 局域网调试界面 - watchOS 版本,显示IP地址和PIN码,控制HTTP调试服务器。
// ============================================================================

import SwiftUI
import Foundation
import Shared

public struct LocalDebugView: View {
    @StateObject private var server = LocalDebugServer()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingDocs = false
    
    public init() {}
    
    public var body: some View {
        List {
            // 服务器状态
            Section {
                HStack {
                    Circle()
                        .fill(server.isRunning ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(server.isRunning ? "运行中" : "已停止")
                        .font(.caption)
                        .foregroundStyle(server.isRunning ? .green : .secondary)
                }
                
                Button(server.isRunning ? "停止" : "启动") {
                    if server.isRunning {
                        stopServer()
                    } else {
                        startServer()
                    }
                }
                .foregroundStyle(server.isRunning ? .red : .blue)
                
                if let error = server.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            
            // 连接信息
            if server.isRunning {
                Section("连接") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("IP")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(server.localIP)
                            .font(.caption.monospaced())
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PIN")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(server.pin)
                            .font(.title3.monospaced().weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("URL")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("http://\(server.localIP):8080")
                            .font(.system(size: 9).monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if server.isRunning, server.pendingOpenAIRequest != nil || server.pendingOpenAIQueueCount > 0 {
                Section {
                    if let pending = server.pendingOpenAIRequest {
                        Text("模型 \(pending.model ?? "未知") · 消息 \(pending.messageCount)")
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
                        Text("剩余 \(server.pendingOpenAIQueueCount - 1) 条")
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
                    Label("API 文档", systemImage: "book")
                        .font(.caption)
                }
            } footer: {
                Text("仅在可信网络使用 · PIN 随机生成 · 用完及时停止")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("调试")
        .sheet(isPresented: $showingDocs) {
            NavigationStack {
                WatchDocumentationView()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active && server.isRunning {
                stopServer()
            }
        }
    }
    
    private func startServer() {
        server.start(port: 8080)
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
    }
    
    private func stopServer() {
        server.stop()
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
            Section("基础") {
                InfoItem(label: "端口", value: "8080")
                InfoItem(label: "Header", value: "X-Debug-PIN")
            }
            
            Section("端点") {
                EndpointItem(method: "POST", path: "/v1/chat/completions", desc: "OpenAI 兼容请求(免 PIN)")
                EndpointItem(method: "GET", path: "/api/list", desc: "列出目录")
                EndpointItem(method: "GET", path: "/api/download", desc: "下载文件")
                EndpointItem(method: "POST", path: "/api/upload", desc: "上传文件")
                EndpointItem(method: "POST", path: "/api/delete", desc: "删除")
                EndpointItem(method: "POST", path: "/api/mkdir", desc: "创建目录")
            }
            
            Section("示例") {
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        Text("列出目录:")
                            .font(.caption2.weight(.medium))
                        Text("""
                        curl -X GET \\
                          http://IP:8080/api/list \\
                          -H "X-Debug-PIN: PIN" \\
                          -d '{"path": "."}'
                        """)
                    }
                    
                    Group {
                        Text("下载文件:")
                            .font(.caption2.weight(.medium))
                            .padding(.top, 4)
                        Text("""
                        curl -X GET \\
                          http://IP:8080/api/download \\
                          -H "X-Debug-PIN: PIN" \\
                          -d '{"path": "file.txt"}'
                        """)
                    }
                    
                    Group {
                        Text("上传文件:")
                            .font(.caption2.weight(.medium))
                            .padding(.top, 4)
                        Text("""
                        curl -X POST \\
                          http://IP:8080/api/upload \\
                          -H "X-Debug-PIN: PIN" \\
                          -d '{"path": "file.txt", "data": "..."}'
                        """)
                    }
                }
                .font(.system(size: 8).monospaced())
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("API 文档")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }
}

private struct InfoItem: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
        }
    }
}

private struct EndpointItem: View {
    let method: String
    let path: String
    let desc: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(method)
                    .font(.system(size: 8).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(methodColor, in: Capsule())
                
                Text(path)
                    .font(.system(size: 10).monospaced())
            }
            Text(desc)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
    
    private var methodColor: Color {
        method == "GET" ? .blue : .green
    }
}

#Preview {
    NavigationView {
        LocalDebugView()
    }
}
