// ============================================================================
// LocalLinuxWorkspaceViews.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 工作区管理只消费后台统计后的摘要；归档与删除均由存储 actor 执行。
// ============================================================================

import ETOSCore
import SwiftUI

struct LocalLinuxWorkspacesView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var workspaces: [LocalAgentWorkspace] = []

    var body: some View {
        Form {
            Section {
                Picker(
                    NSLocalizedString("会话删除后的工作区", comment: "Linux workspace cleanup policy"),
                    selection: $appConfig.localLinuxWorkspaceCleanupPolicy
                ) {
                    Text(NSLocalizedString("保留并手动清理", comment: "Manual Linux workspace cleanup"))
                        .tag("manual")
                    Text(NSLocalizedString("随会话自动删除", comment: "Automatic Linux workspace cleanup"))
                        .tag("automatic")
                }
            } footer: {
                Text(NSLocalizedString("自动删除只作用于以后删除的会话；本地 MCP 的独立工作区仍需手动处理。", comment: "Linux workspace cleanup policy footer"))
            }

            Section(NSLocalizedString("工作区", comment: "Linux workspaces section")) {
                if workspaces.isEmpty {
                    Text(NSLocalizedString("还没有 Linux 工作区。", comment: "No Linux workspaces"))
                        .foregroundStyle(.secondary)
                }
                ForEach(workspaces) { workspace in
                    NavigationLink {
                        LocalLinuxWorkspaceDetailView(workspace: workspace)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(workspaceTitle(workspace))
                            Text(workspace.guestPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(
                                fromByteCount: Int64(clamping: workspace.sizeBytes),
                                countStyle: .file
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("工作区", comment: "Linux workspaces title"))
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

    private func workspaceTitle(_ workspace: LocalAgentWorkspace) -> String {
        if let sessionID = workspace.sessionID {
            return String(
                format: NSLocalizedString("会话 %@", comment: "Linux session workspace title"),
                String(sessionID.uuidString.prefix(8))
            )
        }
        if let profileID = workspace.profileID {
            return String(
                format: NSLocalizedString("本地 MCP %@", comment: "Local MCP workspace title"),
                String(profileID.uuidString.prefix(8))
            )
        }
        return NSLocalizedString("独立工作区", comment: "Standalone Linux workspace title")
    }
}

private struct LocalLinuxWorkspaceDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var workspace: LocalAgentWorkspace
    @State private var exportURL: URL?
    @State private var activeJobCount = 0
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?

    init(workspace: LocalAgentWorkspace) {
        _workspace = State(initialValue: workspace)
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("工作区", comment: "Linux workspace detail section")) {
                LabeledContent(NSLocalizedString("Linux 路径", comment: "Linux workspace guest path"), value: workspace.guestPath)
                LabeledContent(
                    NSLocalizedString("大小", comment: "Linux workspace size"),
                    value: ByteCountFormatter.string(
                        fromByteCount: Int64(clamping: workspace.sizeBytes),
                        countStyle: .file
                    )
                )
                LabeledContent(NSLocalizedString("活动任务", comment: "Linux workspace active jobs"), value: "\(activeJobCount)")
                if let sessionID = workspace.sessionID {
                    LabeledContent(NSLocalizedString("会话", comment: "Linux workspace session"), value: sessionID.uuidString)
                }
                if let profileID = workspace.profileID {
                    LabeledContent(NSLocalizedString("配置", comment: "Linux workspace profile"), value: profileID.uuidString)
                }
            }

            Section {
                Button(NSLocalizedString("准备工作区导出", comment: "Prepare Linux workspace export")) {
                    prepareExport()
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label(NSLocalizedString("共享导出文件", comment: "Share Linux workspace export"), systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text(NSLocalizedString("导出会把当前工作区打包到 Documents/Linux/Exports；原工作区不会被修改。", comment: "Linux workspace export footer"))
            }

            Section {
                Button(NSLocalizedString("删除工作区…", comment: "Delete Linux workspace"), role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
        .navigationTitle(NSLocalizedString("工作区详情", comment: "Linux workspace detail title"))
        .task { await reload() }
        .confirmationDialog(
            NSLocalizedString("删除这个工作区？", comment: "Delete Linux workspace confirmation"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("停止相关任务并删除", comment: "Stop jobs and delete Linux workspace"), role: .destructive) {
                deleteWorkspace()
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("工作区文件与其中的完整输出将被删除，RootFS、Home、Shared 和外部挂载不受影响。", comment: "Delete Linux workspace warning"))
        }
        .alert(NSLocalizedString("工作区操作失败", comment: "Linux workspace operation failure"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(NSLocalizedString("好", comment: "Dismiss"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func reload() async {
        workspace = (try? await LocalLinuxStorageManager.shared.refreshWorkspaceSize(workspace)) ?? workspace
        activeJobCount = await LocalLinuxJobScheduler.shared.activeJobs().filter {
            $0.workspaceID == workspace.id
        }.count
    }

    private func prepareExport() {
        Task {
            do {
                exportURL = try await LocalLinuxStorageManager.shared.exportWorkspace(workspace)
            } catch { errorMessage = error.localizedDescription }
        }
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
