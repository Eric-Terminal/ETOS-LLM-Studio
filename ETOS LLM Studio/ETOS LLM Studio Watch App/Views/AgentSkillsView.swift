// ============================================================================
// AgentSkillsView.swift
// ============================================================================
// Agent Skills 管理页（watchOS）
// - 管理技能列表与启用状态
// - 支持新增、删除、文件编辑、GitHub / URL 导入
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct AgentSkillsView: View {
    @StateObject private var manager = SkillManager.shared
    @State private var showAddSheet = false
    @State private var showImportSheet = false
    @State private var showURLImportSheet = false
    @State private var deleteTarget: SkillMetadata?
    @State private var isShowingIntroDetails = false

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "Agent Skills",
                    summary: "为模型提供自定义技能，通过 use_skill 在聊天中按需调用。",
                    details: """
                    怎么用
                    1. 添加技能（粘贴 SKILL.md 或 GitHub 导入）。
                    2. 确认技能已启用。
                    3. 打开"向模型暴露 Agent Skills"总开关。
                    4. 在聊天中让模型调用对应技能。

                    SKILL.md 格式
                    • frontmatter 必须包含 name 与 description。
                    • 正文可写使用说明、参数等 Markdown 内容。

                    常见问题
                    • 模型不调用：检查总开关与技能启用状态。
                    • 导入失败：确认仓库地址可访问。
                    • 无法本地选文件：可使用链接导入 SKILL.md。
                    • 需要更新内容：在技能详情里编辑 SKILL.md。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle(NSLocalizedString("向模型暴露 Agent Skills", comment: ""),
                    isOn: Binding(
                        get: { manager.chatToolsEnabled },
                        set: { manager.setChatToolsEnabled($0) }
                    )
                )
                Text(NSLocalizedString("关闭后不会向模型提供 use_skill 工具。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("操作", comment: "")) {
                Button {
                    showAddSheet = true
                } label: {
                    Label(NSLocalizedString("新增技能", comment: ""), systemImage: "plus")
                }

                Button {
                    showImportSheet = true
                } label: {
                    Label(NSLocalizedString("GitHub 导入", comment: ""), systemImage: "square.and.arrow.down")
                }

                Button {
                    showURLImportSheet = true
                } label: {
                    Label(NSLocalizedString("链接导入 SKILL.md", comment: ""), systemImage: "link.badge.plus")
                }
            }

            Section(String(format: NSLocalizedString("技能 (%d)", comment: ""), manager.skills.count)) {
                if manager.skills.isEmpty {
                    Text(NSLocalizedString("暂无技能", comment: ""))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.skills) { skill in
                        NavigationLink {
                            WatchSkillDetailView(skillName: skill.name, manager: manager)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(skill.name)
                                    Spacer()
                                    Text(manager.isSkillEnabled(skill.name) ? NSLocalizedString("已启用", comment: "") : NSLocalizedString("已停用", comment: ""))
                                        .etFont(.caption2)
                                        .foregroundStyle(manager.isSkillEnabled(skill.name) ? .green : .secondary)
                                }
                                Text(skill.description)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteTarget = skill
                            } label: {
                                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Agent Skills")
        .onAppear {
            manager.reloadFromDisk()
        }
        .sheet(isPresented: $showAddSheet) {
            WatchAddSkillSheet(manager: manager)
        }
        .sheet(isPresented: $showImportSheet) {
            WatchImportSkillSheet(manager: manager)
        }
        .sheet(isPresented: $showURLImportSheet) {
            WatchImportSkillFromURLSheet(manager: manager)
        }
        .alert(
            NSLocalizedString("删除技能", comment: ""),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { deleteTarget = nil }
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let target = deleteTarget {
                    _ = manager.deleteSkill(target.name)
                }
                deleteTarget = nil
            }
        } message: {
            Text(String(format: NSLocalizedString("确认删除“%@”？", comment: ""), deleteTarget?.name ?? ""))
        }
    }
}

private struct WatchImportSkillFromURLSheet: View {
    @ObservedObject var manager: SkillManager
    @Environment(\.dismiss) private var dismiss
    @State private var fileURLText: String = ""
    @State private var isImporting = false
    @State private var localError: String?

    var body: some View {
        List {
            Section(NSLocalizedString("SKILL.md 链接", comment: "")) {
                TextField("https://example.com/SKILL.md", text: $fileURLText.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text(NSLocalizedString("支持 http/https 的文本链接，下载后按 SKILL.md 规则导入。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if isImporting {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(NSLocalizedString("导入中…", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let localError {
                Section(NSLocalizedString("错误", comment: "")) {
                    Text(localError)
                        .etFont(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button(NSLocalizedString("导入", comment: "")) {
                    startImportFromURL()
                }
                .disabled(isImporting || fileURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(NSLocalizedString("链接导入", comment: ""))
    }

    private func startImportFromURL() {
        let trimmed = fileURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            localError = NSLocalizedString("链接不能为空。", comment: "")
            return
        }
        guard let url = URL(string: trimmed) else {
            localError = NSLocalizedString("链接格式无效，请输入完整 URL。", comment: "")
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            localError = NSLocalizedString("仅支持 http/https 链接。", comment: "")
            return
        }

        isImporting = true
        localError = nil

        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 45
                let (data, response) = try await NetworkSessionConfiguration.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    await MainActor.run {
                        localError = String(format: NSLocalizedString("下载失败：HTTP %d", comment: ""), httpResponse.statusCode)
                        isImporting = false
                    }
                    return
                }

                guard let content = String(data: data, encoding: .utf8), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await MainActor.run {
                        localError = NSLocalizedString("下载内容为空或编码不受支持。", comment: "")
                        isImporting = false
                    }
                    return
                }

                let success = await MainActor.run {
                    manager.saveSkillFromContent(content)
                }

                await MainActor.run {
                    isImporting = false
                    if success {
                        dismiss()
                    } else {
                        localError = manager.lastErrorMessage ?? NSLocalizedString("导入失败：SKILL.md 内容无效。", comment: "")
                    }
                }
            } catch {
                await MainActor.run {
                    localError = error.localizedDescription
                    isImporting = false
                }
            }
        }
    }
}

private extension AgentSkillsView {
    func settingsIntroCard(
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
                Text(NSLocalizedString("进一步了解…", comment: ""))
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
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
}

private struct WatchAddSkillSheet: View {
    @ObservedObject var manager: SkillManager
    @Environment(\.dismiss) private var dismiss
    @State private var content: String = """
---
name: my-skill
description: "技能描述"
---

在这里编写技能说明。
"""
    @State private var localError: String?

    private var parsedName: String {
        SkillFrontmatterParser.parse(content)["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        List {
            Section {
                TextField(NSLocalizedString("SKILL.md 内容", comment: ""), text: $content.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(8...20)
            }

            if !parsedName.isEmpty {
                Section(NSLocalizedString("名称", comment: "")) {
                    Text(parsedName)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let localError {
                Section(NSLocalizedString("错误", comment: "")) {
                    Text(localError)
                        .foregroundStyle(.red)
                        .etFont(.caption2)
                }
            }

            Section {
                Button(NSLocalizedString("保存", comment: "")) {
                    let success = manager.saveSkillFromContent(content)
                    if success {
                        dismiss()
                    } else {
                        localError = manager.lastErrorMessage ?? NSLocalizedString("保存失败。", comment: "")
                    }
                }
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(NSLocalizedString("新增技能", comment: ""))
    }
}

private struct WatchImportSkillSheet: View {
    @ObservedObject var manager: SkillManager
    @Environment(\.dismiss) private var dismiss
    @State private var repoURL = ""
    @State private var isImporting = false
    @State private var localError: String?

    var body: some View {
        List {
            Section(NSLocalizedString("仓库地址", comment: "")) {
                TextField("https://github.com/owner/repo", text: $repoURL.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text(NSLocalizedString("支持 /tree/branch 或子目录。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if isImporting {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(NSLocalizedString("导入中…", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let localError {
                Section(NSLocalizedString("错误", comment: "")) {
                    Text(localError)
                        .etFont(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button(NSLocalizedString("导入", comment: "")) {
                    Task {
                        isImporting = true
                        localError = nil
                        let result = await manager.importSkillFromGitHub(repoURL: repoURL)
                        isImporting = false
                        if result.success {
                            dismiss()
                        } else {
                            localError = result.message
                        }
                    }
                }
                .disabled(isImporting || repoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(NSLocalizedString("GitHub 导入", comment: ""))
    }
}

private struct WatchSkillDetailView: View {
    let skillName: String
    @ObservedObject var manager: SkillManager
    @State private var files: [SkillFileReference] = []
    @State private var showCreateFileSheet = false
    @State private var editingFile: SkillFileReference?
    @State private var deleteTarget: SkillFileReference?

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("在聊天中启用", comment: ""),
                    isOn: Binding(
                        get: { manager.isSkillEnabled(skillName) },
                        set: { manager.setSkillEnabled(name: skillName, isEnabled: $0) }
                    )
                )
            }

            Section(NSLocalizedString("文件", comment: "")) {
                if files.isEmpty {
                    Text(NSLocalizedString("目录为空", comment: ""))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(files) { file in
                        NavigationLink {
                            WatchEditSkillFileView(skillName: skillName, file: file, manager: manager) {
                                reload()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.relativePath)
                                    .etFont(.caption2)
                                Text(StorageUtility.formatSize(file.size))
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if file.relativePath != "SKILL.md" {
                                Button(role: .destructive) {
                                    deleteTarget = file
                                } label: {
                                    Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    showCreateFileSheet = true
                } label: {
                    Label(NSLocalizedString("新建文件", comment: ""), systemImage: "doc.badge.plus")
                }
            }
        }
        .navigationTitle(skillName)
        .onAppear(perform: reload)
        .sheet(isPresented: $showCreateFileSheet) {
            WatchCreateSkillFileView(skillName: skillName, manager: manager) {
                reload()
            }
        }
        .alert(
            NSLocalizedString("删除文件", comment: ""),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )
        ) {
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { deleteTarget = nil }
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let target = deleteTarget {
                    _ = manager.deleteSkillFile(skillName: skillName, relativePath: target.relativePath)
                    reload()
                }
                deleteTarget = nil
            }
        } message: {
            Text(String(format: NSLocalizedString("确认删除“%@”？", comment: ""), deleteTarget?.relativePath ?? ""))
        }
    }

    private func reload() {
        files = manager.listFiles(skillName: skillName)
    }
}

private struct WatchEditSkillFileView: View {
    let skillName: String
    let file: SkillFileReference
    @ObservedObject var manager: SkillManager
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var localError: String?

    var body: some View {
        List {
            Section {
                TextField(NSLocalizedString("文件内容", comment: ""), text: $content.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(8...20)
            }

            if let localError {
                Section(NSLocalizedString("错误", comment: "")) {
                    Text(localError)
                        .foregroundStyle(.red)
                        .etFont(.caption2)
                }
            }

            Section {
                Button(NSLocalizedString("保存", comment: "")) {
                    let success = manager.saveSkillFile(skillName: skillName, relativePath: file.relativePath, content: content)
                    if success {
                        onSaved()
                        dismiss()
                    } else {
                        localError = manager.lastErrorMessage ?? NSLocalizedString("保存失败。", comment: "")
                    }
                }
            }
        }
        .navigationTitle(file.relativePath)
        .onAppear {
            content = manager.readSkillFile(skillName: skillName, relativePath: file.relativePath) ?? ""
        }
    }
}

private struct WatchCreateSkillFileView: View {
    let skillName: String
    @ObservedObject var manager: SkillManager
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var relativePath = ""
    @State private var content = ""
    @State private var localError: String?

    var body: some View {
        List {
            Section(NSLocalizedString("路径", comment: "")) {
                TextField(NSLocalizedString("例如 refs/checklist.md", comment: ""), text: $relativePath.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section(NSLocalizedString("内容", comment: "")) {
                TextField(NSLocalizedString("文件内容", comment: ""), text: $content.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(6...20)
            }

            if let localError {
                Section(NSLocalizedString("错误", comment: "")) {
                    Text(localError)
                        .foregroundStyle(.red)
                        .etFont(.caption2)
                }
            }

            Section {
                Button(NSLocalizedString("创建", comment: "")) {
                    let path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !path.isEmpty else {
                        localError = NSLocalizedString("路径不能为空。", comment: "")
                        return
                    }
                    let success = manager.saveSkillFile(skillName: skillName, relativePath: path, content: content)
                    if success {
                        onSaved()
                        dismiss()
                    } else {
                        localError = manager.lastErrorMessage ?? NSLocalizedString("创建失败。", comment: "")
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("新建文件", comment: ""))
    }
}
