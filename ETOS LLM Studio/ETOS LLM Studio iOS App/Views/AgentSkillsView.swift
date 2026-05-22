// ============================================================================
// AgentSkillsView.swift
// ============================================================================
// Agent Skills 管理页（iOS）
// - 管理技能列表与启用状态
// - 支持新增、删除、文件编辑、GitHub/链接/本地技能包导入
// ============================================================================

import SwiftUI
import Foundation
import Shared
import UniformTypeIdentifiers

struct AgentSkillsView: View {
    @StateObject private var manager = SkillManager.shared
    @State private var showAddSheet = false
    @State private var showImportSheet = false
    @State private var showURLImportSheet = false
    @State private var showLocalImporter = false
    @State private var localImportError: String?
    @State private var deleteTarget: SkillMetadata?
    @State private var isShowingIntroDetails = false

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "Agent Skills",
                    summary: "为模型提供自定义技能文件，通过 use_skill 工具在聊天中按需调用。",
                    details: """
                    适用场景
                    • 你想让模型在聊天时执行特定任务，例如格式化输出、代码检查、知识问答等。
                    • 你希望将常用的提示词或操作封装为可复用的技能模块。

                    怎么用（建议顺序）
                    1. 点击"新增技能"粘贴 SKILL.md，或通过 GitHub / 本地文件导入。
                    2. 确认技能列表中对应技能已启用（右侧开关为开）。
                    3. 打开"向模型暴露 Agent Skills（use_skill）"总开关。
                    4. 在聊天中告知模型你的需求，模型会在合适时机调用 use_skill。

                    SKILL.md 格式说明
                    • 文件头（frontmatter）可声明 name、description、when_to_use 等字段。
                    • 导入目录或仓库时，省略 name 会使用技能目录名；省略 description 会使用正文首段。
                    • name 作为技能的唯一标识，不能与已有技能重名。
                    • 正文可包含使用说明、参数说明、示例等任意 Markdown 内容。

                    常见问题
                    • 模型不调用技能：先检查总开关是否已开启，并确认对应技能已启用。
                    • 导入失败：检查仓库地址是否可访问，或改用本地文件/手动粘贴 SKILL.md 内容。
                    • 技能内容需更新：进入技能详情编辑 SKILL.md 文件即可。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
            }

            Section {
                Toggle(NSLocalizedString("向模型暴露 Agent Skills（use_skill）", comment: ""),
                    isOn: Binding(
                        get: { manager.chatToolsEnabled },
                        set: { manager.setChatToolsEnabled($0) }
                    )
                )
            } footer: {
                Text(NSLocalizedString("关闭后不会向模型提供 use_skill 工具，技能文件仍会保留。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    showAddSheet = true
                } label: {
                    Label(NSLocalizedString("新增技能（粘贴 SKILL.md）", comment: ""), systemImage: "plus")
                }

                Button {
                    showImportSheet = true
                } label: {
                    Label(NSLocalizedString("从 GitHub 导入", comment: ""), systemImage: "square.and.arrow.down")
                }

                Button {
                    showURLImportSheet = true
                } label: {
                    Label(NSLocalizedString("链接导入技能包", comment: ""), systemImage: "link.badge.plus")
                }

                Button {
                    localImportError = nil
                    showLocalImporter = true
                } label: {
                    Label(NSLocalizedString("从本地技能包导入", comment: ""), systemImage: "tray.and.arrow.down")
                }

                if let localImportError {
                    Text(localImportError)
                        .etFont(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section(String(format: NSLocalizedString("已安装技能 (%d)", comment: ""), manager.skills.count)) {
                if manager.skills.isEmpty {
                    Text(NSLocalizedString("暂无技能。可粘贴 SKILL.md，或从 GitHub / 本地技能包导入。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.skills) { skill in
                        NavigationLink {
                            SkillDetailView(skillName: skill.name, manager: manager)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(skill.name)
                                        .etFont(.headline)
                                    Spacer(minLength: 12)
                                    Toggle(
                                        "",
                                        isOn: Binding(
                                            get: { manager.isSkillEnabled(skill.name) },
                                            set: { manager.setSkillEnabled(name: skill.name, isEnabled: $0) }
                                        )
                                    )
                                    .labelsHidden()
                                }
                                Text(skill.description)
                                    .etFont(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                if let compatibility = skill.compatibility, !compatibility.isEmpty {
                                    Text(compatibility)
                                        .etFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
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
            AddSkillSheet(manager: manager)
        }
        .sheet(isPresented: $showImportSheet) {
            ImportSkillSheet(manager: manager)
        }
        .sheet(isPresented: $showURLImportSheet) {
            ImportSkillFromURLSheet(manager: manager)
        }
        .fileImporter(
            isPresented: $showLocalImporter,
            allowedContentTypes: AgentSkillsView.localImportContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleLocalImportResult
        )
        .alert(NSLocalizedString("删除技能", comment: ""), isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { deleteTarget = nil }
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let target = deleteTarget {
                    _ = manager.deleteSkill(target.name)
                }
                deleteTarget = nil
            }
        } message: {
            Text(String(format: NSLocalizedString("确认删除“%@”？此操作不可撤销。", comment: ""), deleteTarget?.name ?? ""))
        }
    }
}

private extension AgentSkillsView {
    static var localImportContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .folder]
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        if let zip = UTType(filenameExtension: "zip") {
            types.append(zip)
        }
        return types
    }

    func handleLocalImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            localImportError = String(format: NSLocalizedString("无法读取本地文件：%@", comment: ""), error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                let shouldStop = url.startAccessingSecurityScopedResource()
                defer {
                    if shouldStop {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let result = try await Task.detached(priority: .utility) {
                        try SkillBundleImporter.importSkill(from: url)
                    }.value
                    let success = await MainActor.run {
                        manager.saveSkillDataFilesAtomically(skillName: result.skillName, files: result.files)
                    }
                    await MainActor.run {
                        if success {
                            localImportError = nil
                        } else {
                            localImportError = manager.lastErrorMessage ?? NSLocalizedString("导入失败：技能包内容无效。", comment: "")
                        }
                    }
                } catch {
                    await MainActor.run {
                        localImportError = String(format: NSLocalizedString("导入失败：%@", comment: ""), error.localizedDescription)
                    }
                }
            }
        }
    }

    func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(title, comment: "Agent Skills 介绍卡片标题"))
                .etFont(.headline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(NSLocalizedString(summary, comment: "Agent Skills 介绍卡片摘要"))
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
                    Text(NSLocalizedString(details, comment: "Agent Skills 介绍卡片详情"))
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
}

private struct AddSkillSheet: View {
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
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("请粘贴完整的 SKILL.md 内容。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)

                TextEditor(text: $content)
                    .etFont(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 280)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    }

                if parsedName.isEmpty {
                    TextField(NSLocalizedString("名称", comment: ""), text: $fallbackName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text(String(format: NSLocalizedString("技能名称：%@", comment: ""), parsedName))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                }
                if let localError {
                    Text(localError)
                        .etFont(.caption)
                        .foregroundStyle(.red)
                }

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle(NSLocalizedString("新增技能", comment: ""))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
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
        }
    }
}

private struct ImportSkillSheet: View {
    @ObservedObject var manager: SkillManager
    @Environment(\.dismiss) private var dismiss
    @State private var repoURL = ""
    @State private var isImporting = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("https://github.com/owner/repo", comment: ""), text: $repoURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(NSLocalizedString("仓库地址", comment: ""))
                } footer: {
                    Text(NSLocalizedString("支持 /tree/branch 或子目录路径。", comment: ""))
                }

                if isImporting {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(NSLocalizedString("正在导入，请稍候…", comment: ""))
                                .etFont(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let localError {
                    Section(NSLocalizedString("错误", comment: "")) {
                        Text(localError)
                            .foregroundStyle(.red)
                            .etFont(.footnote)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("GitHub 导入", comment: ""))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .topBarTrailing) {
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
        }
    }
}

private struct ImportSkillFromURLSheet: View {
    @ObservedObject var manager: SkillManager
    @Environment(\.dismiss) private var dismiss
    @State private var fileURLText = ""
    @State private var isImporting = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("https://example.com/skill.zip", comment: ""), text: $fileURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text(NSLocalizedString("技能包链接", comment: ""))
                } footer: {
                    Text(NSLocalizedString("支持 http/https 的 SKILL.md 或 zip 技能包链接。", comment: ""))
                }

                if isImporting {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(NSLocalizedString("正在导入，请稍候…", comment: ""))
                                .etFont(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let localError {
                    Section(NSLocalizedString("错误", comment: "")) {
                        Text(localError)
                            .foregroundStyle(.red)
                            .etFont(.footnote)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("链接导入", comment: ""))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("导入", comment: "")) {
                        startImportFromURL()
                    }
                    .disabled(isImporting || fileURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
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

private struct SkillDetailView: View {
    let skillName: String
    @ObservedObject var manager: SkillManager
    @State private var files: [SkillFileReference] = []
    @State private var showCreateFileSheet = false
    @State private var editingFile: SkillFileReference?
    @State private var deleteTarget: SkillFileReference?

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("在聊天中启用该技能", comment: ""),
                    isOn: Binding(
                        get: { manager.isSkillEnabled(skillName) },
                        set: { manager.setSkillEnabled(name: skillName, isEnabled: $0) }
                    )
                )
            }

            Section(String(format: NSLocalizedString("文件 (%d)", comment: ""), files.count)) {
                if files.isEmpty {
                    Text(NSLocalizedString("技能目录为空。", comment: ""))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(files) { file in
                        Group {
                            if file.isReadableText {
                                Button {
                                    editingFile = file
                                } label: {
                                    fileRow(file)
                                }
                                .buttonStyle(.plain)
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
        }
        .navigationTitle(skillName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreateFileSheet = true
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(isPresented: $showCreateFileSheet) {
            CreateSkillFileSheet(skillName: skillName, manager: manager) {
                reload()
            }
        }
        .sheet(item: $editingFile) { file in
            EditSkillFileSheet(skillName: skillName, file: file, manager: manager) {
                reload()
            }
        }
        .alert(NSLocalizedString("删除文件", comment: ""), isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
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

    private func fileRow(_ file: SkillFileReference) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.relativePath)
                    .etFont(.footnote.monospaced())
                    .foregroundStyle(.primary)
                Text(fileDetailText(file))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func fileDetailText(_ file: SkillFileReference) -> String {
        let sizeText = StorageUtility.formatSize(file.size)
        guard !file.isReadableText else { return sizeText }
        return "\(sizeText) · \(file.readOnlyReason ?? NSLocalizedString("仅列出", comment: "Skill resource list-only marker"))"
    }
}

private struct EditSkillFileSheet: View {
    let skillName: String
    let file: SkillFileReference
    @ObservedObject var manager: SkillManager
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $content)
                    .etFont(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 300)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    }

                if let localError {
                    Text(localError)
                        .etFont(.caption)
                        .foregroundStyle(.red)
                }

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle(file.relativePath)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("保存", comment: "")) {
                        let success = manager.saveSkillFile(
                            skillName: skillName,
                            relativePath: file.relativePath,
                            content: content
                        )
                        if success {
                            onSaved()
                            dismiss()
                        } else {
                            localError = manager.lastErrorMessage ?? NSLocalizedString("保存失败。", comment: "")
                        }
                    }
                }
            }
            .onAppear {
                content = manager.readSkillFile(skillName: skillName, relativePath: file.relativePath) ?? ""
            }
        }
    }
}

private struct CreateSkillFileSheet: View {
    let skillName: String
    @ObservedObject var manager: SkillManager
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var relativePath = ""
    @State private var content = ""
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("路径", comment: "")) {
                    TextField(NSLocalizedString("例如 refs/checklist.md", comment: ""), text: $relativePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section(NSLocalizedString("内容", comment: "")) {
                    TextEditor(text: $content)
                        .etFont(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 220)
                }

                if let localError {
                    Section(NSLocalizedString("错误", comment: "")) {
                        Text(localError)
                            .foregroundStyle(.red)
                            .etFont(.footnote)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("新建文件", comment: ""))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("创建", comment: "")) {
                        let path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !path.isEmpty else {
                            localError = NSLocalizedString("文件路径不能为空。", comment: "")
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
        }
    }
}
