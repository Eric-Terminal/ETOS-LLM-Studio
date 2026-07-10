// ============================================================================
// AgentSkillsView.swift
// ============================================================================
// Agent Skills 管理页（iOS）
// - 管理技能列表与启用状态
// - 支持新增、删除、文件编辑、GitHub/链接/本地技能包导入
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore
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
                    title: NSLocalizedString("Agent Skills", comment: "Agent Skills intro title"),
                    summary: NSLocalizedString("为模型提供自定义技能文件，通过 use_skill 工具在聊天中按需调用。", comment: "Agent Skills intro summary"),
                    details: NSLocalizedString("Agent Skills 管理说明正文", comment: "Agent Skills intro details"),
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
                            SkillDetailView(initialSkillName: skill.name, manager: manager)
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
    @State private var content: String = NSLocalizedString("默认技能模板", comment: "Default SKILL.md template")
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
    @State private var importDownloadProgress: SyncPackageDownloadProgress?
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
                        SkillImportDownloadProgressView(progress: importDownloadProgress)
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
        importDownloadProgress = SyncPackageDownloadProgress(bytesReceived: 0, totalBytes: 0)
        localError = nil

        Task {
            let result = await manager.importSkillFromURL(urlString: fileURLText) { progress in
                Task { @MainActor in
                    importDownloadProgress = progress
                }
            }
            await MainActor.run {
                isImporting = false
                importDownloadProgress = nil
                if result.success {
                    dismiss()
                } else {
                    localError = result.message
                }
            }
        }
    }
}

private struct SkillImportDownloadProgressView: View {
    let progress: SyncPackageDownloadProgress?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(NSLocalizedString("正在导入，请稍候…", comment: ""))
                Spacer()
                if let progress, progress.totalBytes > 0 {
                    Text(String(format: "%d%%", progress.displayPercentage))
                        .monospacedDigit()
                } else {
                    ProgressView()
                }
            }
            .etFont(.footnote)

            if let progress, progress.totalBytes > 0 {
                ProgressView(value: progress.fractionCompleted)
                Text(
                    String(
                        format: NSLocalizedString("已下载 %@ / %@", comment: ""),
                        StorageUtility.formatTransferSize(progress.bytesReceived),
                        StorageUtility.formatTransferSize(progress.totalBytes)
                    )
                )
                .etFont(.caption)
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SkillDetailView: View {
    let initialSkillName: String
    @ObservedObject var manager: SkillManager
    @State private var skillName: String
    @State private var skill: SkillMetadata?
    @State private var skillBody: String = ""
    @State private var files: [SkillFileReference] = []
    @State private var showEditSkillSheet = false
    @State private var showCreateFileSheet = false
    @State private var editingFile: SkillFileReference?
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
                    Toggle(NSLocalizedString("在聊天中启用该技能", comment: ""),
                        isOn: Binding(
                            get: { manager.isSkillEnabled(skill.name) },
                            set: { manager.setSkillEnabled(name: skill.name, isEnabled: $0) }
                        )
                    )
                }

                Section(NSLocalizedString("编辑", comment: "")) {
                    Button {
                        showEditSkillSheet = true
                    } label: {
                        Label(NSLocalizedString("编辑技能", comment: "Edit skill"), systemImage: "square.and.pencil")
                    }
                }

                Section(NSLocalizedString("基本信息", comment: "")) {
                    Text(skill.name)
                        .etFont(.headline)
                        .textSelection(.enabled)
                    Text(skill.description)
                        .etFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let compatibility = skill.compatibility, !compatibility.isEmpty {
                        LabeledContent(NSLocalizedString("兼容性", comment: "Skill compatibility label")) {
                            Text(compatibility)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !skill.allowedTools.isEmpty {
                        LabeledContent(NSLocalizedString("允许工具", comment: "Skill allowed tools label")) {
                            Text(skill.allowedTools.joined(separator: ", "))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(NSLocalizedString("正文预览", comment: "Skill body preview")) {
                    if skillBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(NSLocalizedString("无正文内容。", comment: "Empty skill body"))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(skillBody)
                            .etFont(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section(String(format: NSLocalizedString("文件 (%d)", comment: ""), files.count)) {
                    Button {
                        showCreateFileSheet = true
                    } label: {
                        Label(NSLocalizedString("新建文件", comment: ""), systemImage: "doc.badge.plus")
                    }

                    if files.isEmpty {
                        Text(NSLocalizedString("技能目录为空。", comment: ""))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(files) { file in
                            Group {
                                if file.relativePath == "SKILL.md" {
                                    Button {
                                        showEditSkillSheet = true
                                    } label: {
                                        fileRow(file)
                                    }
                                    .buttonStyle(.plain)
                                } else if file.isReadableText {
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
            } else {
                Section {
                    Text(NSLocalizedString("技能不存在或已被删除。", comment: "Skill missing"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(skillName)
        .onAppear(perform: reload)
        .sheet(isPresented: $showEditSkillSheet) {
            EditSkillSheet(skillName: skillName, manager: manager) { updatedName in
                skillName = updatedName
                reload()
            }
        }
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

private struct EditSkillSheet: View {
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
        NavigationStack {
            Form {
                Section {
                    if parsedName.isEmpty {
                        TextField(NSLocalizedString("名称", comment: ""), text: $fallbackName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        LabeledContent(NSLocalizedString("名称", comment: "")) {
                            Text(parsedName)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("基本信息", comment: ""))
                } footer: {
                    Text(NSLocalizedString("保存后会更新 SKILL.md，并保留资源文件与启用状态。", comment: "Skill edit footer"))
                }

                Section(NSLocalizedString("SKILL.md 内容", comment: "")) {
                    TextEditor(text: $content)
                        .etFont(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 320)
                }

                if let localError {
                    Section(NSLocalizedString("错误", comment: "")) {
                        Text(localError)
                            .foregroundStyle(.red)
                            .etFont(.footnote)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("编辑技能", comment: "Edit skill"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
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
            .onAppear {
                content = manager.readSkillContent(skillName: skillName) ?? ""
                fallbackName = skillName
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
