// ============================================================================
// ShortcutIntegrationView.swift
// ============================================================================
// ShortcutIntegrationView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct ShortcutIntegrationView: View {
    @Environment(\.openURL) private var openURL
    @StateObject private var manager = ShortcutToolManager.shared
    @StateObject private var toolPermissionCenter = ToolPermissionCenter.shared
    @State private var localError: String?
    @State private var isShowingIntroDetails = false
    @AppStorage("shortcut.bridgeShortcutName") private var bridgeShortcutName: String = "ETOS Shortcut Bridge"

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "快捷指令工具箱",
                    summary: "统一管理快捷指令工具的导入、启用状态与运行模式。",
                    details: """
                    适用场景
                    • 你希望让模型调用 iOS 快捷指令完成自动化任务。
                    • 你需要统一管理导入来源、启用状态和运行模式。

                    怎么用（建议顺序）
                    1. 先在“官方导入快捷指令”下载并运行导入助手。
                    2. 再用“从剪贴板导入清单”批量导入工具定义。
                    3. 打开“向模型暴露快捷指令工具”总开关。
                    4. 逐个工具检查描述、启用状态和运行模式。

                    导入模式说明
                    • 轻度导入：只导入名称，适合先快速接入。
                    • 深度导入：尝试解析 iCloud 分享内容并生成描述；失败会自动降级为仅链接。

                    关键参数说明
                    • 导入快捷指令名称：用于匹配官方导入助手名称。
                    • 桥接快捷指令名称：桥接执行链路所用的快捷指令名称。
                    • 运行模式（单工具）：
                      - 直连优先：先尝试直接执行，再回退桥接。
                      - 桥接优先：先走桥接，再回退直连。
                    • 倒计时自动批准：审批等待秒数，范围 1~30 秒。

                    常见问题
                    • 工具没被调用：先查总开关是否开启、单项是否启用。
                    • 导入失败：看“最近导入结果”中的新增/跳过/无效和冲突名称。
                    • 执行超时：优先确认快捷指令本身可独立运行，再检查桥接名称是否一致。
                    • urlshim / URL Scheme 跳转失败：回到本页先复制清单到剪贴板，再点“从剪贴板导入清单”即可继续。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle(NSLocalizedString("向模型暴露快捷指令工具", comment: ""),
                    isOn: Binding(
                        get: { manager.chatToolsEnabled },
                        set: { manager.setChatToolsEnabled($0) }
                    )
                )
            } header: {
                Text(NSLocalizedString("聊天工具总开关", comment: ""))
            } footer: {
                Text(NSLocalizedString("关闭后不会再把任何快捷指令工具提供给模型，也不会响应聊天中的快捷指令工具调用。导入、编辑和单项启用状态仍会保留。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("官方导入快捷指令", comment: "")) {
                Text(NSLocalizedString("内置官方快捷指令，可一键下载并触发导入流程。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    openURL(manager.officialImportShortcutShareURL)
                } label: {
                    Label(NSLocalizedString("下载官方导入快捷指令", comment: ""), systemImage: "square.and.arrow.down")
                }

                Button {
                    Task {
                        let succeeded = await manager.runOfficialImportShortcut()
                        if !succeeded {
                            localError = manager.lastErrorMessage
                        }
                    }
                } label: {
                    Label(NSLocalizedString("检测并运行导入快捷指令", comment: ""), systemImage: "play.circle")
                }

                TextField(
                    NSLocalizedString("导入快捷指令名称", comment: ""),
                    text: Binding(
                        get: { manager.officialImportShortcutName },
                        set: { manager.officialImportShortcutName = $0 }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Text(
                    String(
                        format: NSLocalizedString("默认名称：%@（可按你的快捷指令名称修改）", comment: ""),
                        ShortcutToolManager.officialImportShortcutDefaultName
                    )
                )
                .etFont(.caption)
                .foregroundStyle(.secondary)
            }

            if let officialStatus = manager.lastOfficialTemplateStatusMessage,
               !officialStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section(NSLocalizedString("当前官方导入状态", comment: "")) {
                    Text(officialStatus)
                        .etFont(.footnote)
                        .foregroundStyle((manager.lastOfficialTemplateRunSucceeded == false) ? .orange : .secondary)
                }
            }

            Section(NSLocalizedString("导入与执行设置", comment: "")) {
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

                Text(NSLocalizedString("常见问题：如果 urlshim / URL Scheme 跳转失败，请先把清单内容复制到剪贴板，再点上面的“从剪贴板导入清单”。", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)

                if manager.isImporting {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(NSLocalizedString("导入进行中", comment: ""))
                            .etFont(.caption)
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
                            Text(NSLocalizedString("取消导入", comment: ""))
                        }
                        .etFont(.caption)
                        .disabled(manager.isCancellingImport)
                    }
                }

                TextField(NSLocalizedString("桥接快捷指令名称", comment: ""), text: $bridgeShortcutName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text(NSLocalizedString("默认会按“直连 -> 桥接”执行；若工具运行模式设为桥接，则按“桥接 -> 直连”。", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("审批自动化", comment: "")) {
                Toggle(NSLocalizedString("启用倒计时自动批准", comment: ""),
                    isOn: Binding(
                        get: { toolPermissionCenter.autoApproveEnabled },
                        set: { toolPermissionCenter.setAutoApproveEnabled($0) }
                    )
                )
                Stepper(
                    value: Binding(
                        get: { toolPermissionCenter.autoApproveCountdownSeconds },
                        set: { toolPermissionCenter.setAutoApproveCountdownSeconds($0) }
                    ),
                    in: 1...30
                ) {
                    Text(String(format: NSLocalizedString("倒计时：%ds", comment: ""), toolPermissionCenter.autoApproveCountdownSeconds))
                }
                .disabled(!toolPermissionCenter.autoApproveEnabled)
                let disabledCount = toolPermissionCenter.disabledAutoApproveTools.count
                Text(String(format: NSLocalizedString("已禁用自动批准工具：%d", comment: ""), disabledCount))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
                if disabledCount > 0 {
                    Button(NSLocalizedString("清空禁用列表", comment: ""), role: .destructive) {
                        toolPermissionCenter.clearDisabledAutoApproveTools()
                    }
                }
            }

            if let summary = manager.lastImportSummary {
                Section(NSLocalizedString("最近导入结果", comment: "")) {
                    row(title: "新增", value: "\(summary.importedCount)")
                    row(title: "跳过", value: "\(summary.skippedCount)")
                    row(title: "无效", value: "\(summary.invalidCount)")
                    if !summary.conflictNames.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(NSLocalizedString("重名冲突", comment: ""))
                                .etFont(.subheadline)
                            Text(summary.conflictNames.joined(separator: "，"))
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let error = localError {
                Section(NSLocalizedString("错误", comment: "")) {
                    Text(error)
                        .foregroundStyle(.red)
                        .etFont(.footnote)
                }
            }

            Section(String(format: NSLocalizedString("已导入快捷指令 (%d)", comment: ""), manager.tools.count)) {
                if manager.tools.isEmpty {
                    Text(NSLocalizedString("尚未导入任何快捷指令。", comment: ""))
                        .foregroundStyle(.secondary)
                } else {
                    if !manager.chatToolsEnabled {
                        Text(NSLocalizedString("当前总开关已关闭，以下快捷指令仅用于管理，不会参与聊天调用。", comment: ""))
                            .etFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(manager.tools) { tool in
                        NavigationLink {
                            ShortcutToolDetailView(toolID: tool.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(tool.displayName)
                                        .etFont(.headline)
                                    Spacer()
                                    Text(
                                        tool.isEnabled
                                        ? NSLocalizedString("已启用", comment: "Shortcut tool enabled status")
                                        : NSLocalizedString("已停用", comment: "Shortcut tool disabled status")
                                    )
                                    .etFont(.caption)
                                    .foregroundStyle(tool.isEnabled ? .green : .secondary)
                                }

                                Text(tool.effectiveDescription)
                                    .etFont(.footnote)
                                    .foregroundStyle(.secondary)

                                Text(String(format: NSLocalizedString("运行模式：%@", comment: ""), runModeLabel(for: tool.runModeHint)))
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)

                                if let importStatusText = importStatusText(for: tool) {
                                    Text(importStatusText)
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                manager.deleteTool(id: tool.id)
                            } label: {
                                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("快捷指令工具箱", comment: ""))
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .etFont(.headline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(summary)
                .etFont(.subheadline)
                .foregroundStyle(.primary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: ""))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(details)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
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
            return NSLocalizedString("直连优先", comment: "")
        case .bridge:
            return NSLocalizedString("桥接优先", comment: "")
        @unknown default:
            return NSLocalizedString("直连优先", comment: "")
        }
    }
}

private struct ShortcutToolDetailView: View {
    let toolID: UUID
    @ObservedObject private var manager = ShortcutToolManager.shared
    @State private var isEditingDescription = false
    @State private var descriptionDraft = ""

    private var tool: ShortcutToolDefinition? {
        manager.tools.first(where: { $0.id == toolID })
    }

    var body: some View {
        List {
            if let tool {
                Section(NSLocalizedString("工具信息", comment: "")) {
                    Text(tool.displayName)
                        .etFont(.headline)
                    Text(tool.name)
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                    if let importStatusText = importStatusText(for: tool) {
                        Text(importStatusText)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                    Toggle(
                        NSLocalizedString("启用", comment: "Enable"),
                        isOn: Binding(
                            get: { tool.isEnabled },
                            set: { manager.setToolEnabled(id: tool.id, isEnabled: $0) }
                        )
                    )
                }

                Section(NSLocalizedString("运行设置", comment: "")) {
                    Picker(NSLocalizedString("运行模式", comment: ""),
                        selection: Binding(
                            get: { tool.runModeHint },
                            set: { manager.setRunModeHint(id: tool.id, runModeHint: $0) }
                        )
                    ) {
                        Text(NSLocalizedString("直连优先", comment: "")).tag(ShortcutRunModeHint.direct)
                        Text(NSLocalizedString("桥接优先", comment: "")).tag(ShortcutRunModeHint.bridge)
                    }
                    .pickerStyle(.segmented)
                    .tint(.blue)
                }

                Section(NSLocalizedString("工具描述", comment: "")) {
                    Text(tool.effectiveDescription)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        descriptionDraft = tool.userDescription ?? ""
                        isEditingDescription = true
                    } label: {
                        Label(NSLocalizedString("编辑描述", comment: ""), systemImage: "square.and.pencil")
                    }

                    Button {
                        Task {
                            await manager.regenerateDescriptionWithLLM(for: tool.id)
                        }
                    } label: {
                        Label(NSLocalizedString("重新生成", comment: ""), systemImage: "arrow.clockwise")
                    }
                }
            } else {
                Text(NSLocalizedString("快捷指令不存在或已被删除。", comment: ""))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("工具设置", comment: ""))
        .sheet(isPresented: $isEditingDescription) {
            if let tool {
                NavigationStack {
                    Form {
                        Section(NSLocalizedString("工具", comment: "")) {
                            Text(tool.displayName)
                            Text(tool.name)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Section(NSLocalizedString("自定义描述", comment: "")) {
                            TextEditor(text: $descriptionDraft)
                                .frame(minHeight: 180)
                        }
                    }
                    .navigationTitle(NSLocalizedString("编辑描述", comment: ""))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(NSLocalizedString("取消", comment: "")) {
                                isEditingDescription = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(NSLocalizedString("保存", comment: "")) {
                                manager.updateUserDescription(id: tool.id, description: descriptionDraft)
                                isEditingDescription = false
                            }
                        }
                    }
                }
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
}
