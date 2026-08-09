// ============================================================================
// LocalAgentPromptProfilesView.swift
// ============================================================================
// ETOS LLM Studio
//
// 使用与全局系统提示词一致的当前内容编辑器与列表管理本地 Agent 提示词。
// ============================================================================

import SwiftUI
import ETOSCore

struct LocalAgentPromptProfilesView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var profiles: [LocalAgentPromptProfile] = []
    @State private var selectedID = LocalAgentPromptStore.builtInProfileID
    @State private var selectedProfile: LocalAgentPromptProfile?
    @State private var selectedPromptDraft = ""
    @State private var editingProfile: LocalAgentPromptProfile?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                FullscreenMultilineTextInput(
                    identity: selectedID,
                    placeholder: NSLocalizedString("提示词内容", comment: "Agent prompt content"),
                    fullScreenTitle: NSLocalizedString("编辑提示词", comment: "Edit Agent prompt"),
                    text: $selectedPromptDraft,
                    lineLimit: 4...10,
                    isEnabled: selectedProfile != nil,
                    onDebouncedSave: updateSelectedPromptContent
                )
            } header: {
                Text(NSLocalizedString("Agent 提示词", comment: "Agent prompt editor section"))
            }

            Section {
                Button {
                    editingProfile = LocalAgentPromptProfile(title: "", content: "")
                } label: {
                    Label(NSLocalizedString("新增提示词", comment: "Create Agent prompt profile"), systemImage: "plus")
                }
            }

            Section {
                ForEach(profiles) { profile in
                    Button {
                        select(profile)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(displayTitle(profile))
                                    .lineLimit(1)
                                Text(displayPreview(profile))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if selectedID == profile.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if !profile.isBuiltIn {
                            Button(role: .destructive) {
                                delete(profile)
                            } label: {
                                Label(NSLocalizedString("删除", comment: "Delete Agent prompt profile"), systemImage: "trash")
                            }
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            editingProfile = profile
                        } label: {
                            Label(NSLocalizedString("编辑", comment: "Edit Agent prompt profile"), systemImage: "square.and.pencil")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            editingProfile = profile
                        } label: {
                            Label(NSLocalizedString("编辑", comment: "Edit Agent prompt profile"), systemImage: "square.and.pencil")
                        }
                        if !profile.isBuiltIn {
                            Button(role: .destructive) {
                                delete(profile)
                            } label: {
                                Label(NSLocalizedString("删除", comment: "Delete Agent prompt profile"), systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("提示词列表", comment: "Agent prompt profiles section"))
            } footer: {
                Text(NSLocalizedString("点按可选为当前提示词，向左滑可删除自定义提示词，向右滑可编辑。只有 Agent 模式会插入这里选中的提示词。", comment: "Agent prompt profiles footer"))
            }
        }
        .navigationTitle(NSLocalizedString("Agent 提示词", comment: "Agent prompt title"))
        .task { await reload() }
        .sheet(item: $editingProfile) { profile in
            LocalAgentPromptEditorView(
                profile: profile,
                canReset: profile.isBuiltIn,
                onSave: save,
                onReset: resetBuiltInProfile
            )
        }
        .alert(
            NSLocalizedString("操作失败", comment: "Agent prompt operation failure"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(NSLocalizedString("好", comment: "Dismiss"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func displayTitle(_ profile: LocalAgentPromptProfile) -> String {
        let title = profile.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? NSLocalizedString("未命名提示词", comment: "Untitled Agent prompt") : title
    }

    private func displayPreview(_ profile: LocalAgentPromptProfile) -> String {
        guard !profile.content.isEmpty else {
            return NSLocalizedString("空提示词（不发送）", comment: "Empty Agent prompt")
        }
        return String(profile.content.prefix(80))
    }

    private func reload() async {
        profiles = await LocalAgentPromptStore.shared.profiles()
        if let configuredID = UUID(uuidString: appConfig.localLinuxActivePromptProfileID),
           profiles.contains(where: { $0.id == configuredID }) {
            selectedID = configuredID
        } else {
            selectedID = LocalAgentPromptStore.builtInProfileID
            appConfig.localLinuxActivePromptProfileID = selectedID.uuidString
        }
        selectedProfile = profiles.first(where: { $0.id == selectedID })
        selectedPromptDraft = selectedProfile?.content ?? ""
    }

    private func select(_ profile: LocalAgentPromptProfile) {
        if selectedProfile?.content != selectedPromptDraft {
            updateSelectedPromptContent(selectedPromptDraft)
        }
        selectedID = profile.id
        selectedProfile = profile
        selectedPromptDraft = profile.content
        appConfig.localLinuxActivePromptProfileID = profile.id.uuidString
    }

    private func updateSelectedPromptContent(_ content: String) {
        guard var profile = selectedProfile else { return }
        profile.content = content
        profile.updatedAt = Date()
        selectedProfile = profile
        Task {
            do {
                try await LocalAgentPromptStore.shared.save(profile)
                if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                    profiles[index] = profile
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save(_ profile: LocalAgentPromptProfile) async throws {
        var savedProfile = profile
        savedProfile.title = savedProfile.title.trimmingCharacters(in: .whitespacesAndNewlines)
        savedProfile.updatedAt = Date()
        try await LocalAgentPromptStore.shared.save(savedProfile)

        if !profiles.contains(where: { $0.id == savedProfile.id }) {
            select(savedProfile)
        }
        await reload()
    }

    private func resetBuiltInProfile() async throws -> LocalAgentPromptProfile {
        let profile = try await LocalAgentPromptStore.shared.resetBuiltInProfile()
        select(profile)
        await reload()
        return profile
    }

    private func delete(_ profile: LocalAgentPromptProfile) {
        Task {
            do {
                try await LocalAgentPromptStore.shared.delete(id: profile.id)
                if selectedID == profile.id {
                    selectedID = LocalAgentPromptStore.builtInProfileID
                    appConfig.localLinuxActivePromptProfileID = selectedID.uuidString
                }
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct LocalAgentPromptEditorView: View {
    let canReset: Bool
    let onSave: (LocalAgentPromptProfile) async throws -> Void
    let onReset: () async throws -> LocalAgentPromptProfile

    @Environment(\.dismiss) private var dismiss
    @State private var draft: LocalAgentPromptProfile
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        profile: LocalAgentPromptProfile,
        canReset: Bool,
        onSave: @escaping (LocalAgentPromptProfile) async throws -> Void,
        onReset: @escaping () async throws -> LocalAgentPromptProfile
    ) {
        self.canReset = canReset
        self.onSave = onSave
        self.onReset = onReset
        _draft = State(initialValue: profile)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(NSLocalizedString("提示词名称", comment: "Agent prompt profile name"), text: $draft.title)
                FullscreenMultilineTextInput(
                    identity: draft.id,
                    placeholder: NSLocalizedString("提示词内容", comment: "Agent prompt content"),
                    fullScreenTitle: NSLocalizedString("编辑提示词", comment: "Edit Agent prompt"),
                    text: $draft.content,
                    lineLimit: 4...10,
                    isEnabled: !isSaving,
                    onDebouncedSave: { _ in }
                )

                if canReset {
                    Button(NSLocalizedString("恢复默认提示词", comment: "Reset built-in Agent prompt")) {
                        reset()
                    }
                    .disabled(isSaving)
                }
            }
            .navigationTitle(NSLocalizedString("编辑提示词", comment: "Edit Agent prompt title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "Save")) {
                        save()
                    }
                    .disabled(isSaving)
                }
            }
            .alert(
                NSLocalizedString("保存失败", comment: "Save Agent prompt failure"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(NSLocalizedString("好", comment: "Dismiss"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await onSave(draft)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func reset() {
        isSaving = true
        Task {
            do {
                draft = try await onReset()
                isSaving = false
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
