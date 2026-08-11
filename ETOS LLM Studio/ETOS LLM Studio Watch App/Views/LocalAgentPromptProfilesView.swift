// ============================================================================
// LocalAgentPromptProfilesView.swift
// ============================================================================
// ETOS LLM Studio Watch
//
// 手表端保持扁平编辑，同时明确这里只管理 Linux 能力说明而不是用户人设。
// ============================================================================

import SwiftUI
import ETOSCore

struct LocalLinuxWatchPromptView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var profiles: [LocalAgentPromptProfile] = []
    @State private var selectedID = LocalAgentPromptStore.builtInProfileID
    @State private var selectedProfile: LocalAgentPromptProfile?
    @State private var selectedPromptDraft = ""
    @State private var isSavingSelectedPrompt = false
    @State private var editingProfile: LocalAgentPromptProfile?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section(NSLocalizedString("Agent 提示词", comment: "Watch Agent prompt editor section")) {
                TextField(
                    NSLocalizedString("提示词内容", comment: "Watch Agent prompt content"),
                    text: $selectedPromptDraft.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                .lineLimit(4...10)
                .disabled(selectedProfile == nil || isSavingSelectedPrompt)

                Button(NSLocalizedString("保存修改", comment: "Watch save Agent prompt")) {
                    saveSelectedPrompt()
                }
                .disabled(
                    selectedProfile == nil
                        || selectedProfile?.content == selectedPromptDraft
                        || isSavingSelectedPrompt
                )
            }

            Section {
                Button {
                    editingProfile = LocalAgentPromptProfile(title: "", content: "")
                } label: {
                    Label(NSLocalizedString("新增提示词", comment: "Watch create Agent prompt profile"), systemImage: "plus")
                }
            }

            Section(NSLocalizedString("提示词列表", comment: "Watch Agent prompt profiles section")) {
                ForEach(profiles) { profile in
                    Button {
                        select(profile)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(displayTitle(profile))
                                    .lineLimit(1)
                                Text(displayPreview(profile))
                                    .font(.caption2)
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
                                Label(NSLocalizedString("删除", comment: "Watch delete Agent prompt profile"), systemImage: "trash")
                            }
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            editingProfile = profile
                        } label: {
                            Label(NSLocalizedString("编辑", comment: "Watch edit Agent prompt profile"), systemImage: "square.and.pencil")
                        }
                        .tint(.blue)
                    }
                }
            }

            Text(NSLocalizedString("这里的内容会作为 Linux 操作说明合并进系统上下文，不会替代用户已有的人设与会话提示词；只有 Agent 模式会插入。点按可选中，向左滑可删除自定义项，向右滑可编辑。", comment: "Watch Agent prompt profiles footer"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(NSLocalizedString("Agent 提示词", comment: "Watch Agent prompt title"))
        .task { await reload() }
        .sheet(item: $editingProfile) { profile in
            LocalLinuxWatchPromptEditorView(
                profile: profile,
                canReset: profile.isBuiltIn,
                onSave: save,
                onReset: resetBuiltInProfile
            )
        }
        .alert(
            NSLocalizedString("操作失败", comment: "Watch Agent prompt operation failure"),
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
        return title.isEmpty ? NSLocalizedString("未命名提示词", comment: "Watch untitled Agent prompt") : title
    }

    private func displayPreview(_ profile: LocalAgentPromptProfile) -> String {
        guard !profile.content.isEmpty else {
            return NSLocalizedString("空提示词（不发送）", comment: "Watch empty Agent prompt")
        }
        return String(profile.content.prefix(48))
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
            saveSelectedPrompt()
        }
        selectedID = profile.id
        selectedProfile = profile
        selectedPromptDraft = profile.content
        appConfig.localLinuxActivePromptProfileID = profile.id.uuidString
    }

    private func saveSelectedPrompt() {
        guard var profile = selectedProfile else { return }
        profile.content = selectedPromptDraft
        profile.updatedAt = Date()
        isSavingSelectedPrompt = true
        Task {
            do {
                try await LocalAgentPromptStore.shared.save(profile)
                if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                    profiles[index] = profile
                }
                isSavingSelectedPrompt = false
            } catch {
                errorMessage = error.localizedDescription
                isSavingSelectedPrompt = false
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

private struct LocalLinuxWatchPromptEditorView: View {
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
            List {
                TextField(NSLocalizedString("提示词名称", comment: "Watch Agent prompt profile name"), text: $draft.title.watchKeyboardNewlineBinding())
                TextField(
                    NSLocalizedString("提示词内容", comment: "Watch Agent prompt content"),
                    text: $draft.content.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                .lineLimit(6...16)

                Button(NSLocalizedString("保存修改", comment: "Watch save Agent prompt")) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)

                if canReset {
                    Button(NSLocalizedString("恢复默认提示词", comment: "Watch reset built-in Agent prompt")) {
                        reset()
                    }
                    .disabled(isSaving)
                }
            }
            .navigationTitle(NSLocalizedString("编辑提示词", comment: "Watch edit Agent prompt title"))
            .alert(
                NSLocalizedString("保存失败", comment: "Watch save Agent prompt failure"),
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
