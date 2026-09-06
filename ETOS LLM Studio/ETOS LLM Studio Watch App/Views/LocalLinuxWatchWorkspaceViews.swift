// ============================================================================
// LocalLinuxWatchWorkspaceViews.swift
// ============================================================================
// ETOS LLM Studio
// ============================================================================

import ETOSCore
import SwiftUI

struct LocalLinuxWatchWorkspacesView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var workspaces: [LocalAgentWorkspace] = []

    var body: some View {
        List {
            Picker(
                NSLocalizedString("删除会话时", comment: "Watch Linux workspace cleanup policy"),
                selection: $appConfig.localLinuxWorkspaceCleanupPolicy
            ) {
                Text(NSLocalizedString("保留工作区", comment: "Watch keep Linux workspace")).tag("manual")
                Text(NSLocalizedString("自动删除工作区", comment: "Watch delete Linux workspace automatically")).tag("automatic")
            }
            if workspaces.isEmpty {
                Text(NSLocalizedString("还没有工作区。", comment: "Watch no Linux workspaces"))
                    .foregroundStyle(.secondary)
            }
            ForEach(workspaces) { workspace in
                NavigationLink {
                    LocalLinuxWatchWorkspaceDetailView(workspace: workspace)
                } label: {
                    VStack(alignment: .leading) {
                        Text(String(workspace.id.uuidString.prefix(8)))
                        Text(workspace.guestPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(clamping: workspace.sizeBytes),
                            countStyle: .file
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Text(NSLocalizedString("自动清理只影响以后删除的聊天会话；本地 MCP 工作区仍保留。", comment: "Watch Linux workspace cleanup footer"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(NSLocalizedString("工作区", comment: "Watch Linux workspaces title"))
        .task { await reload() }
        .onAppear { Task { await reload() } }
    }

    private func reload() async {
        let loaded = await LocalLinuxStorageManager.shared.workspaces()
        var refreshed: [LocalAgentWorkspace] = []
        for workspace in loaded {
            refreshed.append(
                (try? await LocalLinuxStorageManager.shared.refreshWorkspaceSize(workspace)) ?? workspace
            )
        }
        workspaces = refreshed
    }
}

private struct LocalLinuxWatchWorkspaceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var workspace: LocalAgentWorkspace
    @State private var exportURL: URL?
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?

    init(workspace: LocalAgentWorkspace) {
        _workspace = State(initialValue: workspace)
    }

    var body: some View {
        List {
            Text(workspace.guestPath).font(.caption2.monospaced())
            Text(ByteCountFormatter.string(
                fromByteCount: Int64(clamping: workspace.sizeBytes),
                countStyle: .file
            ))
            Button(NSLocalizedString("导出工作区", comment: "Watch export Linux workspace")) {
                Task {
                    do {
                        exportURL = try await LocalLinuxStorageManager.shared.exportWorkspace(workspace)
                    } catch { errorMessage = error.localizedDescription }
                }
            }
            if exportURL != nil {
                Text(NSLocalizedString("导出文件已保存到 Linux/Exports。", comment: "Watch Linux workspace exported"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button(NSLocalizedString("删除工作区", comment: "Watch delete Linux workspace"), role: .destructive) {
                showDeleteConfirmation = true
            }
        }
        .navigationTitle(NSLocalizedString("工作区", comment: "Watch Linux workspace detail title"))
        .task {
            workspace = (try? await LocalLinuxStorageManager.shared.refreshWorkspaceSize(workspace)) ?? workspace
        }
        .confirmationDialog(
            NSLocalizedString("删除这个工作区？", comment: "Watch delete Linux workspace confirmation"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("停止任务并删除", comment: "Watch stop jobs and delete workspace"), role: .destructive) {
                deleteWorkspace()
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("工作区文件和其中的完整输出将被删除。", comment: "Watch delete Linux workspace warning"))
        }
        .alert(NSLocalizedString("操作失败", comment: "Operation failed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(NSLocalizedString("好", comment: "Dismiss"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func deleteWorkspace() {
        Task {
            do {
                let jobs = await LocalLinuxJobScheduler.shared.activeJobs().filter {
                    $0.workspaceID == workspace.id
                }
                for job in jobs {
                    await LocalLinuxJobScheduler.shared.cancel(jobID: job.id)
                }
                try await LocalLinuxStorageManager.shared.deleteWorkspace(workspace)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
