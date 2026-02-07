import SwiftUI
import Foundation
import Shared

struct ShortcutIntegrationView: View {
    @StateObject private var manager = ShortcutToolManager.shared
    @AppStorage("shortcut.bridgeShortcutName") private var bridgeShortcutName: String = "ETOS Shortcut Bridge"

    var body: some View {
        List {
            Section("说明") {
                Text("在 iPhone 导入快捷指令后，这里可查看并控制启用状态。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("支持轻度导入（仅名称）和深度导入（iCloud 链接解析）；深度解析失败会自动降级为仅链接。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("导入") {
                Text("watchOS 不支持直接读取剪贴板，请在 iPhone 端导入后通过设备同步同步到手表。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("桥接快捷指令：\(bridgeShortcutName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if manager.isImporting {
                    Text("导入进行中")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if manager.importProgressTotal > 0 {
                        ProgressView(
                            value: Double(manager.importProgressCompleted),
                            total: Double(manager.importProgressTotal)
                        )
                        Text(
                            String(
                                format: NSLocalizedString("解析进度 %d / %d", comment: ""),
                                manager.importProgressCompleted,
                                manager.importProgressTotal
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }

                    if let currentName = manager.importCurrentItemName, !currentName.isEmpty {
                        Text(
                            String(
                                format: NSLocalizedString("正在处理：%@", comment: ""),
                                currentName
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        manager.cancelOngoingImport()
                    } label: {
                        Text("取消导入")
                    }
                    .font(.caption2)
                }
            }

            if let summary = manager.lastImportSummary {
                Section("最近导入") {
                    Text("新增 \(summary.importedCount)，跳过 \(summary.skippedCount)")
                    if !summary.conflictNames.isEmpty {
                        Text("冲突：\(summary.conflictNames.joined(separator: "，"))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("快捷指令工具 (\(manager.tools.count))") {
                if manager.tools.isEmpty {
                    Text("暂无工具")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.tools) { tool in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(
                                tool.displayName,
                                isOn: Binding(
                                    get: { tool.isEnabled },
                                    set: { manager.setToolEnabled(id: tool.id, isEnabled: $0) }
                                )
                            )
                            Text(tool.effectiveDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let importStatusText = importStatusText(for: tool) {
                                Text(importStatusText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("快捷指令")
    }

    private func importStatusText(for tool: ShortcutToolDefinition) -> String? {
        guard let importMode = stringMetadata(of: tool, key: "importMode") else { return nil }
        if importMode == "light" {
            return NSLocalizedString("导入方式：轻度导入（仅名称）", comment: "")
        }
        if importMode == "deep" {
            let scanStatus = stringMetadata(of: tool, key: "scanStatus")
            if scanStatus == "parsed" {
                return NSLocalizedString("导入方式：深度导入（已解析流程）", comment: "")
            }
            return NSLocalizedString("导入方式：深度导入（仅链接，未解析）", comment: "")
        }
        return nil
    }

    private func stringMetadata(of tool: ShortcutToolDefinition, key: String) -> String? {
        guard let value = tool.metadata[key],
              case .string(let text) = value else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
