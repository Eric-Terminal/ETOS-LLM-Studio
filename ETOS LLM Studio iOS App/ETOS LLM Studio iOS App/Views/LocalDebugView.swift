// ============================================================================
// LocalDebugView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 局域网调试界面 - 显示IP地址和PIN码,控制HTTP调试服务器。
// ============================================================================

import SwiftUI
import Shared

struct LocalDebugView: View {
    @StateObject private var server = LocalDebugServer()
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        List {
            Section {
                if server.isRunning {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(.green)
                        Text("服务器运行中")
                            .foregroundColor(.green)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("局域网 IP", systemImage: "network")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(server.localIP)
                            .font(.system(.title2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("访问 PIN 码", systemImage: "key.fill")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(server.pin)
                            .font(.system(.largeTitle, design: .monospaced))
                            .fontWeight(.bold)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("访问地址", systemImage: "link")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("http://\(server.localIP):8080")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                    
                } else {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .foregroundColor(.secondary)
                        Text("服务器未运行")
                            .foregroundColor(.secondary)
                    }
                }
                
                if let error = server.errorMessage {
                    Label {
                        Text(error)
                            .foregroundColor(.red)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    }
                }
            } header: {
                Text("服务器状态")
            } footer: {
                Text("服务器运行时,可通过局域网访问并管理 Documents 文件夹。")
            }
            
            Section {
                Button(action: {
                    if server.isRunning {
                        stopServer()
                    } else {
                        startServer()
                    }
                }) {
                    HStack {
                        Image(systemName: server.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        Text(server.isRunning ? "停止调试服务器" : "启动调试服务器")
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(server.isRunning ? .red : .blue)
                }
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("功能说明", systemImage: "info.circle")
                        .font(.headline)
                    
                    Text("• 通过命令行工具在局域网内远程操作 Documents 目录")
                    Text("• 支持文件浏览、上传、下载、删除等操作")
                    Text("• 所有请求需要使用上方显示的 PIN 码认证")
                    Text("• 服务器运行时屏幕将保持常亮")
                }
                .font(.footnote)
                .foregroundColor(.secondary)
                
                NavigationLink {
                    DocumentationView()
                } label: {
                    Label("查看 API 文档", systemImage: "book.fill")
                }
            } header: {
                Text("使用说明")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("安全提醒", systemImage: "shield.fill")
                        .font(.headline)
                        .foregroundColor(.orange)
                    
                    Text("⚠️ 仅在可信任的局域网环境中使用此功能")
                    Text("⚠️ PIN 码每次启动随机生成,请勿泄露")
                    Text("⚠️ 建议使用完毕后立即停止服务器")
                }
                .font(.footnote)
            }
        }
        .navigationTitle("局域网调试")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { newPhase in
            // 离开界面时自动停止服务器
            if newPhase != .active && server.isRunning {
                stopServer()
            }
        }
    }
    
    private func startServer() {
        server.start(port: 8080)
        // 保持屏幕常亮
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    private func stopServer() {
        server.stop()
        // 恢复自动锁屏
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

// MARK: - 文档视图

private struct DocumentationView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    Text("API 文档")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Divider()
                    
                    Text("基础信息")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• 服务器端口: 8080")
                        Text("• 内容类型: application/json")
                        Text("• 认证方式: HTTP Header")
                        Text("• Header 名称: X-Debug-PIN")
                    }
                    .font(.body)
                }
                
                Divider()
                
                Group {
                    Text("API 端点")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    APIEndpointCard(
                        title: "列出目录内容",
                        method: "GET",
                        endpoint: "/api/list",
                        description: "列出指定目录下的所有文件和子目录",
                        example: """
                        curl -X GET http://192.168.1.100:8080/api/list \\
                          -H "X-Debug-PIN: 123456" \\
                          -H "Content-Type: application/json" \\
                          -d '{"path": "Providers"}'
                        """
                    )
                    
                    APIEndpointCard(
                        title: "下载文件",
                        method: "GET",
                        endpoint: "/api/download",
                        description: "下载指定文件,返回 Base64 编码的内容",
                        example: """
                        curl -X GET http://192.168.1.100:8080/api/download \\
                          -H "X-Debug-PIN: 123456" \\
                          -H "Content-Type: application/json" \\
                          -d '{"path": "Providers/config.json"}' \\
                          | jq -r '.data' | base64 -d > config.json
                        """
                    )
                    
                    APIEndpointCard(
                        title: "上传文件",
                        method: "POST",
                        endpoint: "/api/upload",
                        description: "上传文件到指定路径,需要 Base64 编码",
                        example: """
                        curl -X POST http://192.168.1.100:8080/api/upload \\
                          -H "X-Debug-PIN: 123456" \\
                          -H "Content-Type: application/json" \\
                          -d "{\\"path\\": \\"test.txt\\", \\"data\\": \\"$(base64 < test.txt)\\"}"
                        """
                    )
                    
                    APIEndpointCard(
                        title: "删除文件/目录",
                        method: "POST",
                        endpoint: "/api/delete",
                        description: "删除指定的文件或目录",
                        example: """
                        curl -X POST http://192.168.1.100:8080/api/delete \\
                          -H "X-Debug-PIN: 123456" \\
                          -H "Content-Type: application/json" \\
                          -d '{"path": "test.txt"}'
                        """
                    )
                    
                    APIEndpointCard(
                        title: "创建目录",
                        method: "POST",
                        endpoint: "/api/mkdir",
                        description: "创建新目录(支持递归创建)",
                        example: """
                        curl -X POST http://192.168.1.100:8080/api/mkdir \\
                          -H "X-Debug-PIN: 123456" \\
                          -H "Content-Type: application/json" \\
                          -d '{"path": "NewFolder/SubFolder"}'
                        """
                    )
                }
                
                Divider()
                
                Group {
                    Text("响应格式")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("成功响应:")
                            .font(.headline)
                        Text("""
                        {
                          "success": true,
                          "path": "...",
                          ...
                        }
                        """)
                        .font(.system(.footnote, design: .monospaced))
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)
                        
                        Text("错误响应:")
                            .font(.headline)
                        Text("""
                        {
                          "success": false,
                          "error": "错误信息"
                        }
                        """)
                        .font(.system(.footnote, design: .monospaced))
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("API 文档")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct APIEndpointCard: View {
    let title: String
    let method: String
    let endpoint: String
    let description: String
    let example: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(method)
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(methodColor)
                    .foregroundColor(.white)
                    .cornerRadius(4)
                
                Text(endpoint)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
            }
            
            Text(title)
                .font(.headline)
            
            Text(description)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("示例:")
                .font(.caption)
                .foregroundColor(.secondary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                Text(example)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    private var methodColor: Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        case "DELETE": return .red
        default: return .gray
        }
    }
}

#Preview {
    NavigationView {
        LocalDebugView()
    }
}
