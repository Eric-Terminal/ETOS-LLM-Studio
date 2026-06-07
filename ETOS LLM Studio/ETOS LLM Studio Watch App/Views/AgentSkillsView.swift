// ============================================================================
// AgentSkillsView.swift
// ============================================================================
// Agent Skills 管理页（watchOS）
// - 管理技能列表与启用状态
// - 支持新增、删除、文件编辑、GitHub / URL 导入
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

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
                    • frontmatter 可声明 name、description、when_to_use 等字段。
                    • 导入目录或仓库时，省略 name 会使用技能目录名；省略 description 会使用正文首段。
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
                    Label(NSLocalizedString("链接导入技能包", comment: ""), systemImage: "link.badge.plus")
                }
            }

            Section(String(format: NSLocalizedString("技能 (%d)", comment: ""), manager.skills.count)) {
                if manager.skills.isEmpty {
                    Text(NSLocalizedString("暂无技能", comment: ""))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.skills) { skill in
                        NavigationLink {
                            WatchSkillDetailView(initialSkillName: skill.name, manager: manager)
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
        .navigationTitle(NSLocalizedString("Agent Skills", comment: ""))
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
            Section(NSLocalizedString("技能包链接", comment: "")) {
                TextField(NSLocalizedString("https://example.com/skill.zip", comment: ""), text: $fileURLText.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text(NSLocalizedString("支持 http/https 的 SKILL.md 或 zip 技能包链接。", comment: ""))
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
        isImporting = true
        localError = nil

        Task {
            let result = await manager.importSkillFromURL(urlString: fileURLText)
            await MainActor.run {
                isImporting = false
                if result.success {
                    dismiss()
                } else {
                    localError = result.message
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
            Text(NSLocalizedString(title, comment: "Agent Skills 介绍卡片标题"))
                .etFont(.footnote.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "Agent Skills 介绍卡片摘要"))
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
                Text(NSLocalizedString(details, comment: "Agent Skills 介绍卡片详情"))
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
    @State private var fallbackName: String = ""
    @State private var localError: String?

    private var parsedName: String {
        SkillFrontmatterParser.parse(content)["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var canSave: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!parsedName.isEmpty || !fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        List {
            Section {
                TextField(NSLocalizedString("SKILL.md 内容", comment: ""), text: $content.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(8...20)
            }

            Section(NSLocalizedString("名称", comment: "")) {
                if parsedName.isEmpty {
                    TextField(NSLocalizedString("名称", comment: ""), text: $fallbackName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
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
                    let success = manager.saveSkillFromContent(content, fallbackName: fallbackName)
                    if success {
                        dismiss()
                    } else {
                        localError = manager.lastErrorMessage ?? NSLocalizedString("保存失败。", comment: "")
                    }
                }
                .disabled(!canSave)
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
                TextField(NSLocalizedString("https://github.com/owner/repo", comment: ""), text: $repoURL.watchKeyboardNewlineBinding())
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
    let initialSkillName: String
    @ObservedObject var manager: SkillManager
    @State private var skillName: String
    @State private var skill: SkillMetadata?
    @State private var skillBody: String = ""
    @State private var files: [SkillFileReference] = []
    @State private var showCreateFileSheet = false
    @State private var deleteTarget: SkillFileReference?

    init(initialSkillName: String, manager: SkillManager) {
        self.initialSkillName = initialSkillName
        _manager = ObservedObject(wrappedValue: manager)
        _skillName = State(initialValue: initialSkillName)
    }

    var body: some View {
        List {
            if let skill {
                Section(NSLocalizedString("启用状态", comment: "")) {
                    Toggle(NSLocalizedString("在聊天中启用", comment: ""),
                        isOn: Binding(
                            get: { manager.isSkillEnabled(skill.name) },
                            set: { manager.setSkillEnabled(name: skill.name, isEnabled: $0) }
                        )
                    )
                }

                Section(NSLocalizedString("编辑", comment: "")) {
                    NavigationLink {
                        WatchEditSkillView(skillName: skill.name, manager: manager) { updatedName in
                            skillName = updatedName
                            reload()
                        }
                    } label: {
                        Label(NSLocalizedString("编辑技能", comment: "Edit skill"), systemImage: "square.and.pencil")
                    }
                }

                Section(NSLocalizedString("基本信息", comment: "")) {
                    Text(skill.name)
                        .etFont(.footnote)
                    Text(skill.description)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    if let compatibility = skill.compatibility, !compatibility.isEmpty {
                        Text(compatibility)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !skill.allowedTools.isEmpty {
                        Text(skill.allowedTools.joined(separator: ", "))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(NSLocalizedString("正文预览", comment: "Skill body preview")) {
                    if skillBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(NSLocalizedString("无正文内容。", comment: "Empty skill body"))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(skillBody)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(NSLocalizedString("文件", comment: "")) {
                    Button {
                        showCreateFileSheet = true
                    } label: {
                        Label(NSLocalizedString("新建文件", comment: ""), systemImage: "doc.badge.plus")
                    }

                    if files.isEmpty {
                        Text(NSLocalizedString("目录为空", comment: ""))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(files) { file in
                            Group {
                                if file.relativePath == "SKILL.md" {
                                    NavigationLink {
                                        WatchEditSkillView(skillName: skill.name, manager: manager) { updatedName in
                                            skillName = updatedName
                                            reload()
                                        }
                                    } label: {
                                        fileRow(file)
                                    }
                                } else if file.isReadableText {
                                    NavigationLink {
                                        WatchEditSkillFileView(skillName: skill.name, file: file, manager: manager) {
                                            reload()
                                        }
                                    } label: {
                                        fileRow(file)
                                    }
                                } else {
                                    fileRow(file)
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
            } else {
                Section {
                    Text(NSLocalizedString("技能不存在或已被删除。", comment: "Skill missing"))
                        .foregroundStyle(.secondary)
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
        skill = manager.skills.first(where: { $0.name == skillName })
        if skill == nil, skillName == initialSkillName {
            skill = manager.skills.first(where: { $0.name == initialSkillName })
        }
        if let skill {
            skillName = skill.name
        }
        skillBody = manager.readSkillBody(skillName: skillName) ?? ""
        files = manager.listFiles(skillName: skillName)
    }

    private func fileRow(_ file: SkillFileReference) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(file.relativePath)
                .etFont(.caption2)
            Text(fileDetailText(file))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func fileDetailText(_ file: SkillFileReference) -> String {
        let sizeText = StorageUtility.formatSize(file.size)
        guard !file.isReadableText else { return sizeText }
        return "\(sizeText) · \(file.readOnlyReason ?? NSLocalizedString("仅列出", comment: "Skill resource list-only marker"))"
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

private struct WatchEditSkillView: View {
    let skillName: String
    @ObservedObject var manager: SkillManager
    let onSaved: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var fallbackName = ""
    @State private var localError: String?

    private var parsedName: String {
        SkillFrontmatterParser.parse(content)["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var resolvedName: String {
        parsedName.isEmpty ? fallbackName.trimmingCharacters(in: .whitespacesAndNewlines) : parsedName
    }

    private var canSave: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !resolvedName.isEmpty
    }

    var body: some View {
        List {
            Section {
                if parsedName.isEmpty {
                    TextField(NSLocalizedString("名称", comment: ""), text: $fallbackName.watchKeyboardNewlineBinding())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Text(parsedName)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(NSLocalizedString("保存后会更新 SKILL.md，并保留资源文件与启用状态。", comment: "Skill edit footer"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text(NSLocalizedString("基本信息", comment: ""))
            }

            Section(NSLocalizedString("SKILL.md 内容", comment: "")) {
                TextField(NSLocalizedString("SKILL.md 内容", comment: ""), text: $content.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(8...24)
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
                    let success = manager.updateSkillContent(
                        oldName: skillName,
                        content: content,
                        fallbackName: fallbackName
                    )
                    if success {
                        onSaved(resolvedName)
                        dismiss()
                    } else {
                        localError = manager.lastErrorMessage ?? NSLocalizedString("更新技能失败。", comment: "Update skill failed")
                    }
                }
                .disabled(!canSave)
            }
        }
        .navigationTitle(NSLocalizedString("编辑技能", comment: "Edit skill"))
        .onAppear {
            content = manager.readSkillContent(skillName: skillName) ?? ""
            fallbackName = skillName
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
