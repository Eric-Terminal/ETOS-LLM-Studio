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
                Toggle(
                    "向模型暴露 Agent Skills",
                    isOn: Binding(
                        get: { manager.chatToolsEnabled },
                        set: { manager.setChatToolsEnabled($0) }
                    )
                )
                Text("关闭后不会向模型提供 use_skill 工具。")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("操作") {
                Button {
                    showAddSheet = true
                } label: {
                    Label("新增技能", systemImage: "plus")
                }

                Button {
                    showImportSheet = true
                } label: {
                    Label("GitHub 导入", systemImage: "square.and.arrow.down")
                }

                Button {
                    showURLImportSheet = true
                } label: {
                    Label("链接导入 SKILL.md", systemImage: "link.badge.plus")
                }
            }

            Section("技能 (\(manager.skills.count))") {
                if manager.skills.isEmpty {
                    Text("暂无技能")
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
                                    Text(manager.isSkillEnabled(skill.name) ? "已启用" : "已停用")
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
                                Label("删除", systemImage: "trash")
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
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                if let target = deleteTarget {
                    _ = manager.deleteSkill(target.name)
                }
                deleteTarget = nil
            }
        } message: {
            Text("确认删除“\(deleteTarget?.name ?? "")”？")
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
            Section("SKILL.md 链接") {
                TextField("https://example.com/SKILL.md", text: $fileURLText.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("支持 http/https 的文本链接，下载后按 SKILL.md 规则导入。")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if isImporting {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("导入中…")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let localError {
                Section("错误") {
                    Text(localError)
                        .etFont(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("导入") {
                    startImportFromURL()
                }
                .disabled(isImporting || fileURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("链接导入")
    }

    private func startImportFromURL() {
        let trimmed = fileURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            localError = "链接不能为空。"
            return
        }
        guard let url = URL(string: trimmed) else {
            localError = "链接格式无效，请输入完整 URL。"
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            localError = "仅支持 http/https 链接。"
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
                        localError = "下载失败：HTTP \(httpResponse.statusCode)"
                        isImporting = false
                    }
                    return
                }

                guard let content = String(data: data, encoding: .utf8), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await MainActor.run {
                        localError = "下载内容为空或编码不受支持。"
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
                        localError = manager.lastErrorMessage ?? "导入失败：SKILL.md 内容无效。"
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
                Text("进一步了解…")
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
                TextField("SKILL.md 内容", text: $content.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(8...20)
            }

            if !parsedName.isEmpty {
                Section("名称") {
                    Text(parsedName)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let localError {
                Section("错误") {
                    Text(localError)
                        .foregroundStyle(.red)
                        .etFont(.caption2)
                }
            }

            Section {
                Button("保存") {
                    let success = manager.saveSkillFromContent(content)
                    if success {
                        dismiss()
                    } else {
                        localError = manager.lastErrorMessage ?? "保存失败。"
                    }
                }
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("新增技能")
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
            Section("仓库地址") {
                TextField("https://github.com/owner/repo", text: $repoURL.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("支持 /tree/branch 或子目录。")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if isImporting {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("导入中…")
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let localError {
                Section("错误") {
                    Text(localError)
                        .etFont(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("导入") {
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
        .navigationTitle("GitHub 导入")
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
                Toggle(
                    "在聊天中启用",
                    isOn: Binding(
                        get: { manager.isSkillEnabled(skillName) },
                        set: { manager.setSkillEnabled(name: skillName, isEnabled: $0) }
                    )
                )
            }

            Section("文件") {
                if files.isEmpty {
                    Text("目录为空")
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
                                    Label("删除", systemImage: "trash")
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
                    Label("新建文件", systemImage: "doc.badge.plus")
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
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                if let target = deleteTarget {
                    _ = manager.deleteSkillFile(skillName: skillName, relativePath: target.relativePath)
                    reload()
                }
                deleteTarget = nil
            }
        } message: {
            Text("确认删除“\(deleteTarget?.relativePath ?? "")”？")
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
                TextField("文件内容", text: $content.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(8...20)
            }

            if let localError {
                Section("错误") {
                    Text(localError)
                        .foregroundStyle(.red)
                        .etFont(.caption2)
                }
            }

            Section {
                Button("保存") {
                    let success = manager.saveSkillFile(skillName: skillName, relativePath: file.relativePath, content: content)
                    if success {
                        onSaved()
                        dismiss()
                    } else {
                        localError = manager.lastErrorMessage ?? "保存失败。"
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
            Section("路径") {
                TextField("例如 refs/checklist.md", text: $relativePath.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("内容") {
                TextField("文件内容", text: $content.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(6...20)
            }

            if let localError {
                Section("错误") {
                    Text(localError)
                        .foregroundStyle(.red)
                        .etFont(.caption2)
                }
            }

            Section {
                Button("创建") {
                    let path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !path.isEmpty else {
                        localError = "路径不能为空。"
                        return
                    }
                    let success = manager.saveSkillFile(skillName: skillName, relativePath: path, content: content)
                    if success {
                        onSaved()
                        dismiss()
                    } else {
                        localError = manager.lastErrorMessage ?? "创建失败。"
                    }
                }
            }
        }
        .navigationTitle("新建文件")
    }
}
