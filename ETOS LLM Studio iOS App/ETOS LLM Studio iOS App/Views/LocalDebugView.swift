// ============================================================================
// LocalDebugView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 局域网调试界面 - 显示IP地址和PIN码,控制HTTP调试服务器。
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct LocalDebugView: View {
    @StateObject private var server = LocalDebugServer()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAPIDoc = false
    
    var body: some View {
        Form {
            // 服务器状态
            Section {
                HStack {
                    Image(systemName: server.isRunning ? "circle.fill" : "circle")
                        .foregroundStyle(server.isRunning ? .green : .secondary)
                        .imageScale(.small)
                    Text(server.isRunning ? "运行中" : "已停止")
                        .foregroundStyle(server.isRunning ? .green : .secondary)
                    Spacer()
                    Button(server.isRunning ? "停止" : "启动") {
                        if server.isRunning {
                            stopServer()
                        } else {
                            startServer()
                        }
                    }
                    .buttonStyle(.borderless)
                    .tint(server.isRunning ? .red : .blue)
                }
                
                if let error = server.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            } header: {
                Text("状态")
            } footer: {
                Text(server.isRunning
                     ? NSLocalizedString("服务器运行时屏幕将保持常亮，需先停止服务器才能离开本页", comment: "")
                     : NSLocalizedString("启动后可通过局域网访问 Documents 目录", comment: ""))
            }
            
            // 连接信息
            if server.isRunning {
                Section("连接信息") {
                    LabeledContent("IP 地址") {
                        Text(server.localIP)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    
                    LabeledContent("端口") {
                        Text("8080")
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    
                    LabeledContent("PIN 码") {
                        Text(server.pin)
                            .font(.title3.monospaced().weight(.semibold))
                            .foregroundStyle(.blue)
                            .textSelection(.enabled)
                    }
                    
                    LabeledContent("URL") {
                        Text("http://\(server.localIP):8080")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if server.isRunning, server.pendingOpenAIRequest != nil || server.pendingOpenAIQueueCount > 0 {
                Section("OpenAI 捕获") {
                    if let pending = server.pendingOpenAIRequest {
                        let modelName = pending.model ?? NSLocalizedString("未知", comment: "")
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(format: NSLocalizedString("收到请求：模型 %@ · 消息数 %d", comment: ""), modelName, pending.messageCount))
                                .font(.subheadline)
                            Text(formatPendingTime(pending.receivedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("保存到本地") {
                                server.resolvePendingOpenAIRequest(save: true)
                            }
                            .buttonStyle(.borderedProminent)
                            
                            Button("忽略") {
                                server.resolvePendingOpenAIRequest(save: false)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } footer: {
                    if server.pendingOpenAIQueueCount > 1 {
                        Text(String(format: NSLocalizedString("队列中还有 %d 条未处理请求", comment: ""), server.pendingOpenAIQueueCount - 1))
                    }
                }
            }
            
            // API 文档
            Section {
                Button {
                    showAPIDoc = true
                } label: {
                    Label("API 文档", systemImage: "book")
                }
            } header: {
                Text("文档")
            } footer: {
                Text("查看所有 API 端点和使用示例")
            }
            
            // 安全提示
            Section {
                Label("仅在可信网络中使用", systemImage: "wifi")
                Label("PIN 码随机生成,请勿泄露", systemImage: "key")
                Label("用完后请及时停止服务", systemImage: "hand.raised")
            } header: {
                Text("安全提示")
            }
            .foregroundStyle(.secondary)
            .font(.footnote)
        }
        .navigationTitle("局域网调试")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(server.isRunning)
        .interactiveDismissDisabled(server.isRunning)
        .sheet(isPresented: $showAPIDoc) {
            NavigationStack {
                DocumentationView(localIP: server.localIP)
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
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    private func stopServer() {
        server.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func formatPendingTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - 文档视图

private struct DocumentationView: View {
    @Environment(\.dismiss) private var dismiss
    let localIP: String
    
    var body: some View {
        List {
            Section {
                InfoRow(label: "端口", value: "8080")
                InfoRow(label: "内容类型", value: "application/json")
                InfoRow(label: "认证 Header", value: "X-Debug-PIN")
                Text(String(format: NSLocalizedString("可用浏览器访问: http://%@:8080/", comment: ""), localIP))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("基础信息")
            }
            
            Section("API 端点") {
                APIEndpointRow(
                    method: "POST",
                    path: "/v1/chat/completions",
                    description: "OpenAI 兼容请求 (免 PIN，支持捕获保存)",
                    example: """
                    curl -X POST http://IP:8080/v1/chat/completions \\
                      -H "Content-Type: application/json" \\
                      -d '{\"model\":\"gpt-4\",\"messages\":[{\"role\":\"system\",\"content\":\"你是...\"},{\"role\":\"user\",\"content\":\"你好\"}]}'
                    """
                )
                
                APIEndpointRow(
                    method: "GET",
                    path: "/api/list",
                    description: "列出目录内容",
                    example: """
                    curl -X GET http://IP:8080/api/list \\
                      -H "X-Debug-PIN: 123456" \\
                      -H "Content-Type: application/json" \\
                      -d '{"path": "Providers"}'
                    """
                )
                
                APIEndpointRow(
                    method: "GET",
                    path: "/api/download",
                    description: "下载文件 (Base64)",
                    example: """
                    curl -X GET http://IP:8080/api/download \\
                      -H "X-Debug-PIN: 123456" \\
                      -H "Content-Type: application/json" \\
                      -d '{"path": "file.txt"}' \\
                      | jq -r '.data' | base64 -d > file.txt
                    """
                )
                
                APIEndpointRow(
                    method: "POST",
                    path: "/api/upload",
                    description: "上传文件 (Base64)",
                    example: """
                    curl -X POST http://IP:8080/api/upload \\
                      -H "X-Debug-PIN: 123456" \\
                      -H "Content-Type: application/json" \\
                      -d "{\\"path\\": \\"file.txt\\", \\"data\\": \\"$(base64 < file.txt)\\"}"
                    """
                )
                
                APIEndpointRow(
                    method: "POST",
                    path: "/api/delete",
                    description: "删除文件或目录",
                    example: """
                    curl -X POST http://IP:8080/api/delete \\
                      -H "X-Debug-PIN: 123456" \\
                      -H "Content-Type: application/json" \\
                      -d '{"path": "file.txt"}'
                    """
                )
                
                APIEndpointRow(
                    method: "POST",
                    path: "/api/mkdir",
                    description: "创建目录 (递归)",
                    example: """
                    curl -X POST http://IP:8080/api/mkdir \\
                      -H "X-Debug-PIN: 123456" \\
                      -H "Content-Type: application/json" \\
                      -d '{"path": "NewFolder/Sub"}'
                    """
                )
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("成功响应")
                        .font(.subheadline.weight(.medium))
                    Text("""
                    {
                      "success": true,
                      "path": "...",
                      ...
                    }
                    """)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    
                    Text("错误响应")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 4)
                    Text(NSLocalizedString("debug_error_response_example", comment: ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } header: {
                Text("响应格式")
            }
        }
        .navigationTitle("API 文档")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

private struct APIEndpointRow: View {
    let method: String
    let path: String
    let description: String
    let example: String
    @State private var showExample = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(method)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(methodColor, in: Capsule())
                
                Text(path)
                    .font(.body.monospaced())
                
                Spacer()
                
                Button {
                    withAnimation {
                        showExample.toggle()
                    }
                } label: {
                    Image(systemName: showExample ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            if showExample {
                VStack(alignment: .leading, spacing: 4) {
                    Text("示例")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(example)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
    
    private var methodColor: Color {
        switch method {
        case "GET": .blue
        case "POST": .green
        case "DELETE": .red
        default: .gray
        }
    }
}

#Preview {
    NavigationView {
        LocalDebugView()
    }
}
