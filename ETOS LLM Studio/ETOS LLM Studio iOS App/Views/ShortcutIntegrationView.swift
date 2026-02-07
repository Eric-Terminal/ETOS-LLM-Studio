import SwiftUI
import Foundation
import Shared

struct ShortcutIntegrationView: View {
    @StateObject private var manager = ShortcutToolManager.shared
    @State private var localError: String?
    @State private var editingTool: ShortcutToolDefinition?
    @State private var descriptionDraft: String = ""
    @AppStorage("shortcut.bridgeShortcutName") private var bridgeShortcutName: String = "ETOS Shortcut Bridge"

    var body: some View {
        List {
            Section("关于快捷指令工具") {
                Text("通过剪贴板 + URL 导入快捷指令清单。导入后可像 MCP 一样控制启用、描述和调用权限。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("轻度导入：仅导入名称，描述可手动编辑或稍后让 AI 生成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("深度导入：包含 iCloud 分享链接，App 会尝试解析流程并生成描述；失败会自动降级为仅链接，不影响导入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("导入与执行设置") {
                Button {
                    Task {
                        _ = await manager.importFromClipboard(triggerURL: nil)
                        localError = manager.lastErrorMessage
                    }
                } label: {
                    Label(
                        manager.isImporting
                            ? NSLocalizedString("导入中，请稍候…", comment: "")
                            : NSLocalizedString("从剪贴板导入清单", comment: ""),
                        systemImage: manager.isImporting ? "hourglass" : "arrow.down.doc"
                    )
                }
                .disabled(manager.isImporting)

                if manager.isImporting {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("导入进行中")
                            .font(.caption)
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
                        .font(.caption)
                    }
                }

                TextField("桥接快捷指令名称", text: $bridgeShortcutName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("默认会按“直连 -> 桥接”执行；若工具运行模式设为桥接，则按“桥接 -> 直连”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let summary = manager.lastImportSummary {
                Section("最近导入结果") {
                    row(title: "新增", value: "\(summary.importedCount)")
                    row(title: "跳过", value: "\(summary.skippedCount)")
                    row(title: "无效", value: "\(summary.invalidCount)")
                    if !summary.conflictNames.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("重名冲突")
                                .font(.subheadline)
                            Text(summary.conflictNames.joined(separator: "，"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let error = localError {
                Section("错误") {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section("已导入快捷指令 (\(manager.tools.count))") {
                if manager.tools.isEmpty {
                    Text("尚未导入任何快捷指令。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.tools) { tool in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(tool.displayName)
                                    .font(.headline)
                                Spacer()
                                Toggle(
                                    "启用",
                                    isOn: Binding(
                                        get: { tool.isEnabled },
                                        set: { manager.setToolEnabled(id: tool.id, isEnabled: $0) }
                                    )
                                )
                                .labelsHidden()
                            }

                            Text(tool.effectiveDescription)
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if let importStatusText = importStatusText(for: tool) {
                                Text(importStatusText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Picker(
                                "运行模式",
                                selection: Binding(
                                    get: { tool.runModeHint },
                                    set: { manager.setRunModeHint(id: tool.id, runModeHint: $0) }
                                )
                            ) {
                                Text("直连优先").tag(ShortcutRunModeHint.direct)
                                Text("桥接优先").tag(ShortcutRunModeHint.bridge)
                            }
                            .pickerStyle(.segmented)

                            HStack {
                                Button {
                                    editingTool = tool
                                    descriptionDraft = tool.userDescription ?? ""
                                } label: {
                                    Label("编辑描述", systemImage: "square.and.pencil")
                                }

                                Button {
                                    Task {
                                        await manager.regenerateDescriptionWithLLM(for: tool.id)
                                    }
                                } label: {
                                    Label("重新生成", systemImage: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("快捷指令工具箱")
        .sheet(item: $editingTool) { tool in
            NavigationStack {
                Form {
                    Section("工具") {
                        Text(tool.displayName)
                        Text(tool.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("自定义描述") {
                        TextEditor(text: $descriptionDraft)
                            .frame(minHeight: 180)
                    }
                }
                .navigationTitle("编辑描述")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            editingTool = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            manager.updateUserDescription(id: tool.id, description: descriptionDraft)
                            editingTool = nil
                        }
                    }
                }
            }
        }
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
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
