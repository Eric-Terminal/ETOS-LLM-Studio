// ============================================================================
// RemoteSnapshotBrowserView.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 端从 S3/R2 兼容对象存储列出 .elsbackup 快照，并在确认后下载。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

struct RemoteSnapshotBrowserView: View {
    let configuration: S3CompatibleUploadConfiguration

    @State private var snapshots: [S3CompatibleRemoteSnapshot] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Text(NSLocalizedString("显示当前 S3/R2 配置路径下的 .elsbackup 文件。选择文件后会进入详情页，确认大小与修改时间后再下载恢复。", comment: ""))
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
                        NavigationLink {
                            RemoteSnapshotDetailView(
                                snapshot: snapshot,
                                configuration: configuration
                            )
                        } label: {
                            remoteSnapshotRow(snapshot)
                        }
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
                .disabled(isLoading)
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
    }

    @ViewBuilder
    private func remoteSnapshotRow(_ snapshot: S3CompatibleRemoteSnapshot) -> some View {
        Label {
            Text(snapshot.fileName)
                .etFont(.body)
                .lineLimit(1)
        } icon: {
            Image(systemName: "doc")
                .foregroundStyle(.blue)
        }
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
}

private struct RemoteSnapshotDetailView: View {
    let snapshot: S3CompatibleRemoteSnapshot
    let configuration: S3CompatibleUploadConfiguration

    @State private var isDownloading = false
    @State private var downloadProgress: SyncPackageDownloadProgress?
    @State private var errorMessage: String?
    @State private var restorePayload: IncomingSnapshotRestorePayload?

    var body: some View {
        List {
            Section(NSLocalizedString("远端快照", comment: "")) {
                LabeledContent(NSLocalizedString("文件名", comment: "")) {
                    Text(snapshot.fileName)
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent(NSLocalizedString("远端路径", comment: "")) {
                    Text(snapshot.key)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }

                if let byteSize = snapshot.byteSize {
                    LabeledContent(NSLocalizedString("大小", comment: "")) {
                        Text(StorageUtility.formatSize(byteSize))
                    }
                }

                if let lastModified = snapshot.lastModified {
                    LabeledContent(NSLocalizedString("修改时间", comment: "")) {
                        Text(lastModified.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }

            Section {
                Button {
                    Task {
                        await download()
                    }
                } label: {
                    HStack {
                        Spacer()
                        if isDownloading {
                            ProgressView()
                            Text(NSLocalizedString("正在下载快照…", comment: ""))
                        } else {
                            Label(NSLocalizedString("下载", comment: ""), systemImage: "tray.and.arrow.down")
                        }
                        Spacer()
                    }
                }
                .disabled(isDownloading)

                if let downloadProgress {
                    SnapshotDownloadProgressView(progress: downloadProgress)
                }
            }
        }
        .navigationTitle(snapshot.fileName)
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

    @MainActor
    private func download() async {
        isDownloading = true
        errorMessage = nil
        if let byteSize = snapshot.byteSize {
            downloadProgress = SyncPackageDownloadProgress(bytesReceived: 0, totalBytes: byteSize)
        } else {
            downloadProgress = nil
        }
        do {
            let fileURL = try await SyncPackageUploadService.downloadRemoteSnapshot(
                objectKey: snapshot.key,
                s3: configuration,
                progress: { progress in
                    Task { @MainActor in
                        downloadProgress = progress
                    }
                }
            )
            isDownloading = false
            restorePayload = IncomingSnapshotRestorePayload(fileURL: fileURL)
        } catch {
            isDownloading = false
            downloadProgress = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct SnapshotDownloadProgressView: View {
    let progress: SyncPackageDownloadProgress

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(NSLocalizedString("下载进度", comment: ""))
                Spacer()
                if progress.totalBytes > 0 {
                    Text(String(format: "%.0f%%", progress.fractionCompleted * 100))
                        .monospacedDigit()
                }
            }
            .etFont(.footnote)

            if progress.totalBytes > 0 {
                ProgressView(value: progress.fractionCompleted)
                Text(progressText)
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                Text(NSLocalizedString("正在下载快照…", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var progressText: String {
        String(
            format: NSLocalizedString("已下载 %@ / %@", comment: ""),
            StorageUtility.formatSize(progress.bytesReceived),
            StorageUtility.formatSize(progress.totalBytes)
        )
    }
}
