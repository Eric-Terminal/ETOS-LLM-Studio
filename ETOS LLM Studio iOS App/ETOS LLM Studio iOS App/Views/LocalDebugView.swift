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
    
    var body: some View {
        Form {
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
                        .font(.footnote)
                }
            } header: {
                Text("状态")
            }
            
            // 连接配置
            if !server.isRunning {
                Section(header: Text("服务器地址")) {
                    TextField("输入地址", text: $serverURL, prompt: Text("192.168.1.100:8765"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.body.monospaced())
                    
                    Button("连接") {
                        connectToServer()
                    }
                    .disabled(serverURL.isEmpty)
                } footer: {
                    Text("在电脑上运行 debug_server.py 后输入显示的地址")
                }
            } else {
                Section("连接信息") {
                    LabeledContent("服务器") {
                        Text(server.serverURL)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    
                    Button("断开") {
                        disconnectServer()
                    }
                    .tint(.red)
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
            
            // 使用说明
            Section {
                Button {
                    showAPIDoc = true
                } label: {
                    Label("使用说明", systemImage: "book")
                }
            } header: {
                Text("文档")
            } footer: {
                Text("反向探针模式 · 主动连接电脑")
            }
            
            // 安全提示
            Section {
                Label("仅在可信网络中使用", systemImage: "wifi")
                Label("用完后请及时断开连接", systemImage: "hand.raised")
            } header: {
                Text("提示")
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
                DocumentationView()
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

// MARK: - 文档视图

private struct DocumentationView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        List {
            Section("工作原理") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone")
                            .font(.title2)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Image(systemName: "desktopcomputer")
                            .font(.title2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    
                    Text("设备主动连接电脑端 WebSocket 服务器，接收命令并执行文件操作。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("启动步骤") {
                StepRow(number: 1, title: "电脑端下载并运行", detail: "https://github.com/Eric-Terminal/ETOS-LLM-Studio/blob/main/docs/debug-tools/debug_server.py")
                StepRow(number: 2, title: "记录 IP", detail: "脚本会显示电脑的局域网 IP 地址")
                StepRow(number: 3, title: "输入并连接", detail: "在本界面输入 IP 地址和端口（默认 8765）")
                StepRow(number: 4, title: "开始操作", detail: "电脑端会显示交互式菜单，选择操作即可")
            }
            
            Section("功能") {
                FeatureRow(icon: "📂", title: "文件管理", description: "列出、下载、上传、删除文件和目录")
                FeatureRow(icon: "📥", title: "OpenAI 捕获", description: "转发 API 请求到设备，在设备上确认是否保存")
                FeatureRow(icon: "🎯", title: "菜单操作", description: "电脑端提供图形化菜单，无需手动输入命令")
            }
            
            Section("OpenAI 代理设置") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("将 OpenAI API Base URL 设置为：")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("http://电脑IP:8080")
                        .font(.body.monospaced())
                        .foregroundStyle(.blue)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    
                    Text("发送的请求会转发到设备，设备会弹出确认对话框。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("优势") {
                Label("绕过 watchOS 服务器限制", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("无需 PIN 码验证", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("菜单式操作更友好", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .navigationTitle("使用说明")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") {
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
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.blue))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
            Text(icon)
                .font(.largeTitle)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
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
