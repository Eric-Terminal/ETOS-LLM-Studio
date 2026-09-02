// ============================================================================
// MCPConfigurationTransferView.swift
// ============================================================================
// ETOS LLM Studio iOS App
// ============================================================================

import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

private struct MCPConfigurationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct MCPConfigurationTransferView: View {
    @StateObject private var manager = MCPManager.shared
    @State private var isImporting = false
    @State private var exportDocument: MCPConfigurationDocument?
    @State private var isExporting = false
    @State private var isShowingSecretExportConfirmation = false
    @State private var pendingSensitiveImport: MCPServerConfigurationImportResult?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Button {
                    isImporting = true
                } label: {
                    Label(NSLocalizedString("导入 mcpServers JSON", comment: "Import MCP JSON button"), systemImage: "square.and.arrow.down")
                }

                Button {
                    prepareExport(includeSecrets: false)
                } label: {
                    Label(NSLocalizedString("导出配置", comment: "Export MCP JSON button"), systemImage: "square.and.arrow.up")
                }

                Button {
                    isShowingSecretExportConfirmation = true
                } label: {
                    Label(NSLocalizedString("导出配置与凭据", comment: "Export MCP JSON with secrets button"), systemImage: "key")
                }
            } header: {
                Text(NSLocalizedString("JSON 迁移", comment: "MCP JSON transfer section"))
            } footer: {
                Text(NSLocalizedString("兼容常见 mcpServers 对象。内置 MCP 不会导出；普通导出会移除名称中含 token、key、secret、auth、password 或 cookie 的值。导入不会安装任何本地命令或依赖。", comment: "MCP JSON transfer footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("MCP 配置迁移", comment: "MCP transfer navigation title"))
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "mcp.json"
        ) { result in
            if case .failure(let error) = result {
                message = error.localizedDescription
            }
            exportDocument = nil
        }
        .confirmationDialog(
            NSLocalizedString("导出内容会包含凭据", comment: "MCP secret export confirmation title"),
            isPresented: $isShowingSecretExportConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("继续导出", comment: "Confirm MCP secret export"), role: .destructive) {
                prepareExport(includeSecrets: true)
            }
            Button(NSLocalizedString("取消", comment: "Cancel button"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("导出的环境变量、Header 和 API Key 可能可以直接访问你的服务。请只保存到可信位置。", comment: "MCP secret export warning"))
        }
        .alert(
            NSLocalizedString("导入包含敏感字段", comment: "MCP sensitive import alert title"),
            isPresented: Binding(
                get: { pendingSensitiveImport != nil },
                set: { if !$0 { pendingSensitiveImport = nil } }
            )
        ) {
            Button(NSLocalizedString("导入", comment: "Confirm import button")) {
                if let pendingSensitiveImport {
                    persist(pendingSensitiveImport)
                }
                pendingSensitiveImport = nil
            }
            Button(NSLocalizedString("取消", comment: "Cancel button"), role: .cancel) {
                pendingSensitiveImport = nil
            }
        } message: {
            Text(NSLocalizedString("这些配置含可能属于令牌、密钥、认证、密码或 Cookie 的字段。导入后会保存在 SQLCipher 数据库并参与跨设备同步。", comment: "MCP sensitive import alert message"))
        }
        .alert(
            NSLocalizedString("MCP 配置迁移", comment: "MCP transfer result alert title"),
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )
        ) {
            Button(NSLocalizedString("好的", comment: "OK button")) { message = nil }
        } message: {
            Text(message ?? "")
        }
        .guideSettingsPageContext(
            id: "mcp-configuration-transfer",
            title: NSLocalizedString("MCP 配置迁移", comment: "MCP 配置迁移向导上下文标题"),
            documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Toolbox")],
            settings: [
                .readOnly(
                    "configured_server_count",
                    label: NSLocalizedString("已配置服务器数量", comment: "MCP 配置迁移向导字段"),
                    value: { .int(manager.servers.count) }
                ),
                .readOnly(
                    "supported_format",
                    label: NSLocalizedString("支持的迁移格式", comment: "MCP 配置迁移向导字段"),
                    value: { .string("mcpServers JSON") }
                ),
                .readOnly(
                    "secrets_are_excluded_by_default",
                    label: NSLocalizedString("默认去除敏感字段", comment: "MCP 配置迁移向导字段"),
                    value: { .bool(true) }
                )
            ]
        )
    }

    private func prepareExport(includeSecrets: Bool) {
        do {
            exportDocument = MCPConfigurationDocument(
                data: try MCPServerConfigurationTransferService.exportConfigurations(
                    manager.servers,
                    includeSecrets: includeSecrets
                )
            )
            isExporting = true
        } catch {
            message = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result { message = error.localizedDescription }
            return
        }
        Task {
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    return try MCPServerConfigurationTransferService.importConfigurations(from: data)
                }.value
                if imported.sensitiveServerNames.isEmpty {
                    persist(imported)
                } else {
                    pendingSensitiveImport = imported
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func persist(_ result: MCPServerConfigurationImportResult) {
        result.servers.forEach { manager.save(server: $0) }
        let imported = result.servers.count
        let skipped = result.skippedNames.count
        message = String(
            format: NSLocalizedString("已导入 %d 台 MCP Server，跳过 %d 项。", comment: "MCP import result message"),
            imported,
            skipped
        )
    }
}
