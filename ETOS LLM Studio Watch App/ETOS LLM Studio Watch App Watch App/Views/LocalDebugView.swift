// ============================================================================
// LocalDebugView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 局域网调试界面 - watchOS 版本,显示IP地址和PIN码,控制HTTP调试服务器。
// ============================================================================

import SwiftUI
import Shared

public struct LocalDebugView: View {
    @StateObject private var server = LocalDebugServer()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingDocs = false
    
    public init() {}
    
    public var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // 服务器状态
                if server.isRunning {
                    VStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.title2)
                            .foregroundColor(.green)
                        Text("运行中")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("未运行")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                // IP 地址
                if server.isRunning {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("IP", systemImage: "network")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(server.localIP)
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // PIN 码
                    VStack(alignment: .leading, spacing: 4) {
                        Label("PIN", systemImage: "key.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(server.pin)
                            .font(.system(.title3, design: .monospaced))
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // 访问地址
                    VStack(alignment: .leading, spacing: 4) {
                        Text("http://\(server.localIP):8080")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // 错误信息
                if let error = server.errorMessage {
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 4)
                }
                
                Divider()
                
                // 控制按钮
                Button(action: {
                    if server.isRunning {
                        stopServer()
                    } else {
                        startServer()
                    }
                }) {
                    HStack {
                        Image(systemName: server.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        Text(server.isRunning ? "停止" : "启动")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(server.isRunning ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                
                // 文档按钮
                Button(action: {
                    showingDocs = true
                }) {
                    HStack {
                        Image(systemName: "book.fill")
                        Text("查看文档")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                
                // 提示信息
                VStack(alignment: .leading, spacing: 4) {
                    Label("功能", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("在局域网内通过命令行远程操作 Documents 目录")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                
                // 安全提醒
                VStack(alignment: .leading, spacing: 4) {
                    Label("安全", systemImage: "shield.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text("仅在可信任的局域网中使用")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
        }
        .navigationTitle("局域网调试")
        .sheet(isPresented: $showingDocs) {
            NavigationView {
                WatchDocumentationView()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 离开界面时自动停止服务器
            if newPhase != .active && server.isRunning {
                stopServer()
            }
        }
    }
    
    private func startServer() {
        server.start(port: 8080)
        // watchOS 保持屏幕常亮
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
    }
    
    private func stopServer() {
        server.stop()
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = false
    }
}

// MARK: - 文档视图 (watchOS)

private struct WatchDocumentationView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("API 端点")
                    .font(.headline)
                
                Group {
                    WatchAPICard(
                        method: "GET",
                        endpoint: "/api/list",
                        description: "列出目录"
                    )
                    
                    WatchAPICard(
                        method: "GET",
                        endpoint: "/api/download",
                        description: "下载文件"
                    )
                    
                    WatchAPICard(
                        method: "POST",
                        endpoint: "/api/upload",
                        description: "上传文件"
                    )
                    
                    WatchAPICard(
                        method: "POST",
                        endpoint: "/api/delete",
                        description: "删除文件"
                    )
                    
                    WatchAPICard(
                        method: "POST",
                        endpoint: "/api/mkdir",
                        description: "创建目录"
                    )
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("认证")
                        .font(.headline)
                    Text("所有请求需包含 Header:")
                        .font(.caption2)
                    Text("X-Debug-PIN: <PIN码>")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.blue)
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("示例 (curl)")
                        .font(.headline)
                    Text("""
                    curl -X GET \\
                      http://IP:8080/api/list \\
                      -H "X-Debug-PIN: 123456" \\
                      -d '{"path": "."}'
                    """)
                    .font(.system(.caption2, design: .monospaced))
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                }
            }
            .padding()
        }
        .navigationTitle("API 文档")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
    }
}

private struct WatchAPICard: View {
    let method: String
    let endpoint: String
    let description: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(method)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(methodColor)
                    .foregroundColor(.white)
                    .cornerRadius(3)
                
                Text(endpoint)
                    .font(.system(.caption2, design: .monospaced))
            }
            
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
    }
    
    private var methodColor: Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        default: return .gray
        }
    }
}

#Preview {
    NavigationView {
        LocalDebugView()
    }
}
