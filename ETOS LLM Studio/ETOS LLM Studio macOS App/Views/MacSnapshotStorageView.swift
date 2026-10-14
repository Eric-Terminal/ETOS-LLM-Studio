import ETOSCore
import SwiftUI

struct MacSnapshotStorageView: View {
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var remoteConfiguration: S3CompatibleUploadConfiguration?
    @State private var browsing = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField(NSLocalizedString("对象存储 Endpoint", comment: ""), text: $configuration.syncBackupUploadEndpoint)
                TextField(NSLocalizedString("区域", comment: ""), text: $configuration.syncBackupS3Region)
                TextField(NSLocalizedString("存储桶名称", comment: ""), text: $configuration.syncBackupS3Bucket)
                TextField(NSLocalizedString("备份路径前缀（可选）", comment: ""), text: $configuration.syncBackupS3KeyPrefix)
            }
            Section {
                SecureField(NSLocalizedString("Access Key ID", comment: ""), text: $configuration.syncBackupS3AccessKeyID)
                SecureField(NSLocalizedString("Secret Access Key", comment: ""), text: $configuration.syncBackupS3SecretAccessKey)
                SecureField(NSLocalizedString("Session Token（可选）", comment: ""), text: $configuration.syncBackupS3SessionToken)
            }
            Section {
                Button(NSLocalizedString("远端快照", comment: "")) {
                    do { remoteConfiguration = try Self.storageConfiguration(configuration); browsing = true }
                    catch { self.error = error.localizedDescription }
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("S3/R2 保存设置", comment: ""))
        .navigationDestination(isPresented: $browsing) {
            if let remoteConfiguration { MacRemoteSnapshotsView(configuration: remoteConfiguration) }
        }
        .guideSettingsPageContext(
            id: "mac-snapshot-storage", title: NSLocalizedString("S3/R2 保存设置", comment: ""),
            documents: SnapshotBackupGuideSupport.documents,
            settings: SnapshotBackupGuideSupport.storageSettings
        )
    }

    @MainActor
    static func storageConfiguration(_ store: AppConfigStore) throws -> S3CompatibleUploadConfiguration {
        let endpoint = store.syncBackupUploadEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GuideModelSetupValidation.isValidRemoteBaseURL(endpoint), let url = URL(string: endpoint),
              !store.syncBackupS3Region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !store.syncBackupS3Bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !store.syncBackupS3AccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !store.syncBackupS3SecretAccessKey.isEmpty else {
            throw NSError(domain: "ETOSMacSnapshot", code: 2, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("请先完整配置 S3/R2 地址、区域、存储桶和凭据。", comment: "")
            ])
        }
        return S3CompatibleUploadConfiguration(
            endpoint: url, region: store.syncBackupS3Region, bucket: store.syncBackupS3Bucket,
            keyPrefix: store.syncBackupS3KeyPrefix, accessKeyID: store.syncBackupS3AccessKeyID,
            secretAccessKey: store.syncBackupS3SecretAccessKey, sessionToken: store.syncBackupS3SessionToken
        )
    }
}

private struct MacRemoteSnapshotsView: View {
    let configuration: S3CompatibleUploadConfiguration
    @StateObject private var model = MacRemoteSnapshotsModel()

    var body: some View {
        List {
            if model.isLoading { ProgressView(NSLocalizedString("正在读取远端快照…", comment: "")) }
            ForEach(model.rows) { row in
                NavigationLink {
                    MacRemoteSnapshotDetail(row: row, configuration: configuration)
                } label: {
                    VStack(alignment: .leading) {
                        Text(row.snapshot.fileName)
                        Text(row.sizeAndDate).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !model.isLoading && model.rows.isEmpty {
                ContentUnavailableView(NSLocalizedString("未找到远端快照", comment: ""), systemImage: "tray")
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle(NSLocalizedString("远端快照", comment: ""))
        .toolbar {
            Button { Task { await model.load(configuration) } } label: {
                Label(NSLocalizedString("刷新", comment: ""), systemImage: "arrow.clockwise")
            }.disabled(model.isLoading)
        }
        .task { await model.load(configuration) }
        .guideSettingsPageContext(
            id: "mac-remote-snapshots", title: NSLocalizedString("远端快照", comment: ""),
            documents: SnapshotBackupGuideSupport.documents,
            settings: [
                .readOnly("loading", label: NSLocalizedString("正在读取远端快照…", comment: ""), value: { .bool(model.isLoading) }),
                .readOnly("count", label: NSLocalizedString("远端快照", comment: ""), value: { .int(model.rows.count) })
            ]
        )
    }
}

private struct MacRemoteSnapshotDetail: View {
    let row: MacRemoteSnapshotsModel.Row
    let configuration: S3CompatibleUploadConfiguration
    @StateObject private var model = MacRemoteSnapshotDownloadModel()

    var body: some View {
        Form {
            Section {
                LabeledContent(NSLocalizedString("文件名", comment: ""), value: row.snapshot.fileName)
                LabeledContent(NSLocalizedString("远端路径", comment: ""), value: row.snapshot.key)
                Text(row.sizeAndDate).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(NSLocalizedString("下载", comment: "")) { model.download(row.snapshot, configuration: configuration) }
                    .disabled(model.isDownloading)
                if model.isDownloading {
                    if let progress = model.progress, progress.totalBytes > 0 { ProgressView(value: progress.fractionCompleted) }
                    else { ProgressView(NSLocalizedString("正在下载快照…", comment: "")) }
                    Button(NSLocalizedString("取消", comment: "")) { model.cancel() }
                }
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .navigationTitle(row.snapshot.fileName)
        .sheet(item: $model.incoming) { file in MacSnapshotRestoreSheet(file: file) { model.incoming = nil } }
        .onDisappear { model.cancel() }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-remote-snapshot-\(row.id)"), title: NSLocalizedString("远端快照", comment: ""),
            documents: SnapshotBackupGuideSupport.documents,
            settings: [
                .readOnly("file_name", label: NSLocalizedString("文件名", comment: ""), value: { .string(row.snapshot.fileName) }),
                .readOnly("downloading", label: NSLocalizedString("正在下载快照…", comment: ""), value: { .bool(model.isDownloading) }),
                .readOnly("requires_manual_action", label: NSLocalizedString("下载", comment: ""), value: { .bool(true) })
            ]
        )
    }
}
