// ============================================================================
// ShortcutIntegrationView.swift
// ============================================================================
// ShortcutIntegrationView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct ShortcutIntegrationView: View {
    @Environment(\.openURL) private var openURL
    @StateObject private var manager = ShortcutToolManager.shared
    @StateObject private var toolPermissionCenter = ToolPermissionCenter.shared
    @State private var isShowingIntroDetails = false
    @AppStorage("shortcut.bridgeShortcutName") private var bridgeShortcutName: String = "ETOS Shortcut Bridge"

    private var countdownNumberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "快捷指令工具箱",
                    summary: "在手表端查看并管理已同步的快捷指令工具。",
                    details: """
                    快速上手
                    1. 在 iPhone 端完成导入。
                    2. 手表端确认工具已同步并按需启用。
                    3. 打开“向模型暴露快捷指令工具”总开关。

                    导入模式
                    • 轻度导入：仅名称，配置速度快。
                    • 深度导入：解析 iCloud 链接并尝试生成描述；失败会降级为仅链接。

                    关键项说明
                    • 运行模式：
                      - 直连优先：先直接执行。
                      - 桥接优先：先经桥接快捷指令。
                    • 自动批准：审批倒计时（1~30 秒）。

                    提示
                    • watchOS 不支持直接读剪贴板，建议在 iPhone 完成导入后同步到手表。
                    • 如果工具不可用，先检查总开关和单项启用状态。
                    • 如果 urlshim / URL Scheme 在 iPhone 跳转失败，请回到 iPhone 的快捷设定页，复制清单到剪贴板后使用“从剪贴板导入清单”。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section(
                header: Text("聊天工具总开关"),
                footer: Text("关闭后不会向模型暴露任何快捷指令工具，但导入和单项配置仍会保留。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(
                    "向模型暴露快捷指令工具",
                    isOn: Binding(
                        get: { manager.chatToolsEnabled },
                        set: { manager.setChatToolsEnabled($0) }
                    )
                )
            }

            Section("官方导入快捷指令") {
                Text("内置官方快捷指令，可一键下载并触发导入流程。")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                Text("在 iPhone 上点击“检测并运行导入快捷指令”，手表端会自动同步结果。")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    openURL(manager.officialImportShortcutShareURL)
                } label: {
                    Label("下载官方导入快捷指令", systemImage: "square.and.arrow.down")
                }

                Text(
                    String(
                        format: NSLocalizedString("默认名称：%@（可按你的快捷指令名称修改）", comment: ""),
                        manager.officialImportShortcutName
                    )
                )
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            }

            if let officialStatus = manager.lastOfficialTemplateStatusMessage,
               !officialStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("当前官方导入状态") {
                    Text(officialStatus)
                        .etFont(.caption2)
                        .foregroundStyle((manager.lastOfficialTemplateRunSucceeded == false) ? .orange : .secondary)
                }
            }

            Section("导入") {
                Text("watchOS 不支持直接读取剪贴板，请在 iPhone 端导入后通过设备同步同步到手表。")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                Text("若 iPhone 端 urlshim / URL Scheme 跳转失败，请在 iPhone 的快捷设定页直接复制清单到剪贴板，再使用“从剪贴板导入清单”。")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                Text("桥接快捷指令：\(bridgeShortcutName)")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)

                if manager.isImporting {
                    Text("导入进行中")
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    if manager.isCancellingImport {
                        Text(NSLocalizedString("正在取消导入，请稍候…", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.orange)
                    }

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
                        .etFont(.caption2)
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
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        manager.cancelOngoingImport()
                    } label: {
                        Text("取消导入")
                    }
                    .etFont(.caption2)
                    .disabled(manager.isCancellingImport)
                }
            }

            Section(
                header: Text("审批自动化"),
                footer: Text("倒计时范围 1-30 秒，超出会自动修正。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Toggle(
                    "自动批准",
                    isOn: Binding(
                        get: { toolPermissionCenter.autoApproveEnabled },
                        set: { toolPermissionCenter.setAutoApproveEnabled($0) }
                    )
                )

                HStack {
                    Text("倒计时秒数")
                    Spacer()
                    TextField(
                        "数量",
                        value: Binding(
                            get: { toolPermissionCenter.autoApproveCountdownSeconds },
                            set: { toolPermissionCenter.setAutoApproveCountdownSeconds($0) }
                        ),
                        formatter: countdownNumberFormatter
                    )
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                }
                .disabled(!toolPermissionCenter.autoApproveEnabled)
            }

            if let summary = manager.lastImportSummary {
                Section("最近导入") {
                    Text("新增 \(summary.importedCount)，跳过 \(summary.skippedCount)")
                    if !summary.conflictNames.isEmpty {
                        Text("冲突：\(summary.conflictNames.joined(separator: "，"))")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("快捷指令工具 (\(manager.tools.count))") {
                if manager.tools.isEmpty {
                    Text("暂无工具")
                        .foregroundStyle(.secondary)
                } else {
                    if !manager.chatToolsEnabled {
                        Text("当前总开关已关闭，以下快捷指令仅用于管理，不会参与聊天调用。")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(manager.tools) { tool in
                        NavigationLink {
                            ShortcutToolDetailView(toolID: tool.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(tool.displayName)
                                    Spacer()
                                    Text(
                                        tool.isEnabled
                                        ? NSLocalizedString("已启用", comment: "Shortcut tool enabled status")
                                        : NSLocalizedString("已停用", comment: "Shortcut tool disabled status")
                                    )
                                    .etFont(.caption2)
                                    .foregroundStyle(tool.isEnabled ? .green : .secondary)
                                }
                                Text(tool.effectiveDescription)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text("运行模式：\(runModeLabel(for: tool.runModeHint))")
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                                if let importStatusText = importStatusText(for: tool) {
                                    Text(importStatusText)
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                manager.deleteTool(id: tool.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("快捷指令")
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .etFont(.footnote.weight(.semibold))
            Text(summary)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text("进一步了解…")
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.14))
        )
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(details)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
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

    private func runModeLabel(for runModeHint: ShortcutRunModeHint) -> String {
        switch runModeHint {
        case .direct:
            return "直连优先"
        case .bridge:
            return "桥接优先"
        @unknown default:
            return "直连优先"
        }
    }
}

private struct ShortcutToolDetailView: View {
    let toolID: UUID
    @ObservedObject private var manager = ShortcutToolManager.shared

    private var tool: ShortcutToolDefinition? {
        manager.tools.first(where: { $0.id == toolID })
    }

    var body: some View {
        List {
            if let tool {
                Section("工具信息") {
                    Text(tool.displayName)
                        .etFont(.headline)
                    Text(tool.name)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    if let importStatusText = importStatusText(for: tool) {
                        Text(importStatusText)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("启用状态") {
                    Toggle(
                        NSLocalizedString("启用", comment: "Enable"),
                        isOn: Binding(
                            get: { tool.isEnabled },
                            set: { manager.setToolEnabled(id: tool.id, isEnabled: $0) }
                        )
                    )
                }

                Section("运行设置") {
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
                }

                Section("工具描述") {
                    Text(tool.effectiveDescription)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)

                    Button {
                        Task {
                            await manager.regenerateDescriptionWithLLM(for: tool.id)
                        }
                    } label: {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                }
            } else {
                Text("快捷指令不存在或已被删除。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("工具设置")
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
