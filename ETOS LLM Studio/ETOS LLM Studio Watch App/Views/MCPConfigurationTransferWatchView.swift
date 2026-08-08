// ============================================================================
// MCPConfigurationTransferWatchView.swift
// ============================================================================
// ETOS LLM Studio Watch App
// ============================================================================

import ETOSCore
import SwiftUI

struct MCPConfigurationTransferWatchView: View {
    @StateObject private var manager = MCPManager.shared
    @State private var document = "{\n  \"mcpServers\": {}\n}"
    @State private var pendingSensitiveImport: MCPServerConfigurationImportResult?
    @State private var message: String?

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("mcpServers JSON", comment: "Watch MCP JSON section")),
                footer: Text(NSLocalizedString("可通过 iPhone 键盘粘贴配置。不会自动安装本地命令或依赖；导出会移除敏感字段。", comment: "Watch MCP JSON footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                TextField(
                    NSLocalizedString("mcpServers JSON", comment: "Watch MCP JSON editor"),
                    text: $document.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                    .font(.caption.monospaced())
                    .lineLimit(6...16)
                    .buttonStyle(.plain)
            }

            Section {
                Button(NSLocalizedString("导入", comment: "Import button")) {
                    importDocument()
                }
                Button(NSLocalizedString("生成去敏导出", comment: "Watch export redacted MCP JSON")) {
                    exportDocument()
                }
            }
        }
        .navigationTitle(NSLocalizedString("MCP 迁移", comment: "Watch MCP transfer navigation title"))
        .alert(
            NSLocalizedString("导入包含敏感字段", comment: "MCP sensitive import alert title"),
            isPresented: Binding(
                get: { pendingSensitiveImport != nil },
                set: { if !$0 { pendingSensitiveImport = nil } }
            )
        ) {
            Button(NSLocalizedString("导入", comment: "Confirm import button")) {
                if let pendingSensitiveImport { persist(pendingSensitiveImport) }
                pendingSensitiveImport = nil
            }
            Button(NSLocalizedString("取消", comment: "Cancel button"), role: .cancel) {
                pendingSensitiveImport = nil
            }
        } message: {
            Text(NSLocalizedString("检测到可能属于令牌、密钥、认证、密码或 Cookie 的字段。导入后会进入 SQLCipher 数据库并参与同步。", comment: "Watch MCP sensitive import warning"))
        }
        .alert(
            NSLocalizedString("MCP 迁移", comment: "Watch MCP transfer result title"),
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )
        ) {
            Button(NSLocalizedString("好的", comment: "OK button")) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func importDocument() {
        do {
            let result = try MCPServerConfigurationTransferService.importConfigurations(
                from: Data(document.utf8)
            )
            if result.sensitiveServerNames.isEmpty {
                persist(result)
            } else {
                pendingSensitiveImport = result
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func exportDocument() {
        do {
            document = String(
                decoding: try MCPServerConfigurationTransferService.exportConfigurations(
                    manager.servers,
                    includeSecrets: false
                ),
                as: UTF8.self
            )
        } catch {
            message = error.localizedDescription
        }
    }

    private func persist(_ result: MCPServerConfigurationImportResult) {
        result.servers.forEach { manager.save(server: $0) }
        message = String(
            format: NSLocalizedString("已导入 %d 台，跳过 %d 项。", comment: "Watch MCP import result"),
            result.servers.count,
            result.skippedNames.count
        )
    }
}
