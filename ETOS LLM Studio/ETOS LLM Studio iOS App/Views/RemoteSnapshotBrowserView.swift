// ============================================================================
// RemoteSnapshotBrowserView.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 端从 S3/R2 兼容对象存储列出并下载 .elsbackup 快照。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

struct RemoteSnapshotBrowserView: View {
    let configuration: S3CompatibleUploadConfiguration

    @State private var snapshots: [S3CompatibleRemoteSnapshot] = []
    @State private var isLoading = false
    @State private var downloadingSnapshotID: String?
    @State private var errorMessage: String?
    @State private var restorePayload: IncomingSnapshotRestorePayload?

    var body: some View {
        List {
            Section {
                Text(NSLocalizedString("显示当前 S3/R2 配置路径下的 .elsbackup 文件。选择后会先下载到本机临时目录，再进入恢复确认。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            if isLoading {
                Section {
                    HStack {
                        ProgressView()
                        Text(NSLocalizedString("正在读取远端快照…", comment: ""))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if snapshots.isEmpty && !isLoading {
                    ContentUnavailableView(
                        NSLocalizedString("未找到远端快照", comment: ""),
                        systemImage: "tray",
                        description: Text(NSLocalizedString("当前存储桶路径下没有 .elsbackup 文件。", comment: ""))
                    )
                } else {
                    ForEach(snapshots) { snapshot in
                        Button {
                            Task {
                                await download(snapshot)
                            }
                        } label: {
                            remoteSnapshotRow(snapshot)
                        }
                        .disabled(downloadingSnapshotID != nil)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("远端快照", comment: ""))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await loadSnapshots()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading || downloadingSnapshotID != nil)
                .accessibilityLabel(NSLocalizedString("刷新", comment: ""))
            }
        }
        .refreshable {
            await loadSnapshots()
        }
        .task {
            guard snapshots.isEmpty else { return }
            await loadSnapshots()
        }
        .alert(NSLocalizedString("快照操作失败", comment: ""), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(NSLocalizedString("好", comment: ""), role: .cancel) {}
        } message: {
            Text(errorMessage ?? NSLocalizedString("未知错误", comment: ""))
        }
        .sheet(item: $restorePayload) { payload in
            NavigationStack {
                IncomingSnapshotRestoreView(fileURL: payload.fileURL) {
                    try? FileManager.default.removeItem(at: payload.fileURL)
                    restorePayload = nil
                }
            }
        }
    }

    @ViewBuilder
    private func remoteSnapshotRow(_ snapshot: S3CompatibleRemoteSnapshot) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(snapshot.fileName)
                    .etFont(.body)
                    .foregroundStyle(.primary)
                Text(snapshot.key)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    if let byteSize = snapshot.byteSize {
                        Text(String(format: NSLocalizedString("大小：%@", comment: ""), StorageUtility.formatSize(byteSize)))
                    }
                    if let lastModified = snapshot.lastModified {
                        Text(String(format: NSLocalizedString("修改时间：%@", comment: ""), lastModified.formatted(date: .abbreviated, time: .shortened)))
                    }
                }
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if downloadingSnapshotID == snapshot.id {
                ProgressView()
            }
        }
        .contentShape(Rectangle())
    }

    @MainActor
    private func loadSnapshots() async {
        isLoading = true
        errorMessage = nil
        do {
            snapshots = try await SyncPackageUploadService.listRemoteSnapshots(s3: configuration)
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func download(_ snapshot: S3CompatibleRemoteSnapshot) async {
        downloadingSnapshotID = snapshot.id
        errorMessage = nil
        do {
            let fileURL = try await SyncPackageUploadService.downloadRemoteSnapshot(
                objectKey: snapshot.key,
                s3: configuration
            )
            downloadingSnapshotID = nil
            restorePayload = IncomingSnapshotRestorePayload(fileURL: fileURL)
        } catch {
            downloadingSnapshotID = nil
            errorMessage = error.localizedDescription
        }
    }
}
