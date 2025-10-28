// ============================================================================
// ExportView.swift (iOS)
// ============================================================================
// 通过局域网导出会话
// - 输入目标设备的 IP:Port
// - 展示导出状态提示
// ============================================================================

import SwiftUI
import Shared

struct ExportView: View {
    let session: ChatSession
    let onExport: (ChatSession, String, @escaping (ExportStatus) -> Void) -> Void
    
    @State private var ipAddress: String = ""
    @State private var status: ExportStatus = .idle
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            Section(header: Text("目标")) {
                LabeledContent("会话") {
                    Text(session.name)
                }
                TextField("输入 IP:Port", text: $ipAddress)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            
            Section {
                Button {
                    export()
                } label: {
                    Label("发送到电脑", systemImage: "arrow.up.forward.circle.fill")
                }
                .disabled(ipAddress.isEmpty || isExporting)
            }
            
            Section("状态") {
                statusView
            }
        }
        .navigationTitle("网络导出")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
    }
    
    private var isExporting: Bool {
        if case .exporting = status { return true }
        return false
    }
    
    private func export() {
        status = .exporting
        onExport(session, ipAddress) { result in
            status = result
        }
    }
    
    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            Text("等待导出…").foregroundStyle(.secondary)
        case .exporting:
            HStack {
                ProgressView()
                Text("正在发送")
            }
        case .success:
            Label("导出成功", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("导出失败", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        @unknown default:
            Text("未知状态").foregroundStyle(.orange)
        }
    }
}
