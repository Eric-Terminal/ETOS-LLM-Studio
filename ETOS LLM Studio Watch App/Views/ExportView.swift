// ============================================================================
// ExportView.swift
// ============================================================================
// ETOS LLM Studio Watch App 网络导出视图
//
// 功能特性:
// - 提供输入 IP 地址的界面
// - 调用导出功能并将结果（成功/失败）反馈给用户
// ============================================================================

import SwiftUI

/// 用于通过网络导出聊天记录的视图
struct ExportView: View {
    
    // MARK: - 属性与操作
    
    let session: ChatSession
    let onExport: (ChatSession, String, @escaping (ExportStatus) -> Void) -> Void
    
    // MARK: - 状态
    
    @State private var ipAddress: String = ""
    @State private var status: ExportStatus = .idle
    
    // MARK: - 环境
    
    @Environment(\.dismiss) var dismiss

    // MARK: - 视图主体
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("导出会话: \(session.name)")
                        .font(.headline)
                        .padding(.bottom, 10)

                    TextField("输入 IP:Port", text: $ipAddress)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)

                    Button(action: export) {
                        Text("发送到电脑")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ipAddress.isEmpty || {
                        if case .exporting = status { return true }
                        return false
                    }())

                    Spacer()

                    statusView
                        .padding(.top, 10)
                }
                .padding()
            }
            .navigationTitle("网络导出")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - 私有方法
    
    private func export() {
        status = .exporting
        onExport(session, ipAddress) { result in
            status = result
        }
    }

    // MARK: - 辅助视图
    
    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            Text("等待导出...")
                .foregroundColor(.secondary)
        case .exporting:
            ProgressView("正在发送...")
        case .success:
            VStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("导出成功！")
            }
        case .failed(let reason):
            VStack {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text("导出失败: \(reason)")
                    .font(.caption)
            }
        }
    }
}
