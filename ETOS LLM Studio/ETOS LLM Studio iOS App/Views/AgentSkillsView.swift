// ============================================================================
// AgentSkillsView.swift
// ============================================================================
// Agent Skills 管理页（iOS）
// - 管理技能列表与启用状态
// - 支持新增、删除、文件编辑、GitHub 导入
// ============================================================================

import SwiftUI
import Shared

struct AgentSkillsView: View {
    @StateObject private var manager = SkillManager.shared
    @State private var showAddSheet = false
    @State private var showImportSheet = false
    @State private var deleteTarget: SkillMetadata?

    var body: some View {
        List {
            Section {
                Toggle(
                    "向模型暴露 Agent Skills（use_skill）",
                    isOn: Binding(
                        get: { manager.chatToolsEnabled },
                        set: { manager.setChatToolsEnabled($0) }
                    )
                )
            } footer: {
                Text("关闭后不会向模型提供 use_skill 工具，技能文件仍会保留。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    showAddSheet = true
                } label: {
                    Label("新增技能（粘贴 SKILL.md）", systemImage: "plus")
                }

                Button {
                    showImportSheet = true
                } label: {
                    Label("从 GitHub 导入", systemImage: "square.and.arrow.down")
                }
            }

            Section("已安装技能 (\(manager.skills.count))") {
                if manager.skills.isEmpty {
                    Text("暂无技能。可粘贴 SKILL.md 或从 GitHub 导入。")
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
            AddSkillSheet(manager: manager)
        }
        .sheet(isPresented: $showImportSheet) {
            ImportSkillSheet(manager: manager)
        }
        .alert("删除技能", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                if let target = deleteTarget {
                    _ = manager.deleteSkill(target.name)
                }
                deleteTarget = nil
            }
        } message: {
            Text("确认删除“\(deleteTarget?.name ?? "")”？此操作不可撤销。")
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
    @State private var localError: String?

    private var parsedName: String {
        SkillFrontmatterParser.parse(content)["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("请粘贴完整的 SKILL.md 内容。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)

                TextEditor(text: $content)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 280)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    }

                if !parsedName.isEmpty {
                    Text("技能名称：\(parsedName)")
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
            .navigationTitle("新增技能")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
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
                    TextField("https://github.com/owner/repo", text: $repoURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("仓库地址")
                } footer: {
                    Text("支持 /tree/branch 或子目录路径。")
                }

                if isImporting {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在导入，请稍候…")
                                .etFont(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let localError {
                    Section("错误") {
                        Text(localError)
                            .foregroundStyle(.red)
                            .etFont(.footnote)
                    }
                }
            }
            .navigationTitle("GitHub 导入")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .disabled(isImporting)
                }
                ToolbarItem(placement: .topBarTrailing) {
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
                Toggle(
                    "在聊天中启用该技能",
                    isOn: Binding(
                        get: { manager.isSkillEnabled(skillName) },
                        set: { manager.setSkillEnabled(name: skillName, isEnabled: $0) }
                    )
                )
            }

            Section("文件 (\(files.count))") {
                if files.isEmpty {
                    Text("技能目录为空。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(files) { file in
                        Button {
                            editingFile = file
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.relativePath)
                                        .etFont(.footnote.monospaced())
                                        .foregroundStyle(.primary)
                                    Text(StorageUtility.formatSize(file.size))
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
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
        .alert("删除文件", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
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
                    .font(.system(.footnote, design: .monospaced))
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
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        let success = manager.saveSkillFile(
                            skillName: skillName,
                            relativePath: file.relativePath,
                            content: content
                        )
                        if success {
                            onSaved()
                            dismiss()
                        } else {
                            localError = manager.lastErrorMessage ?? "保存失败。"
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
                Section("路径") {
                    TextField("例如 refs/checklist.md", text: $relativePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("内容") {
                    TextEditor(text: $content)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 220)
                }

                if let localError {
                    Section("错误") {
                        Text(localError)
                            .foregroundStyle(.red)
                            .etFont(.footnote)
                    }
                }
            }
            .navigationTitle("新建文件")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("创建") {
                        let path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !path.isEmpty else {
                            localError = "文件路径不能为空。"
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
        }
    }
}
