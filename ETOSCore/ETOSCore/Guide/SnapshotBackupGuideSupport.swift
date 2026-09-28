import SwiftUI

/// 两端共用备份字段白名单；保存、上传与覆盖恢复仍由用户在原生页面发起。
@MainActor
public enum SnapshotBackupGuideSupport {
    public static var documents: [GuideDocumentReference] {
        [GuideDocumentReference(id: "snapshot-backup", title: NSLocalizedString("快照备份", comment: ""))]
    }

    public static func draftSettings(
        kind: Binding<SnapshotBuilder.BackupKind>,
        encrypted: Binding<Bool>,
        strongDerivation: Binding<Bool>,
        password: Binding<String>,
        confirmation: Binding<String>
    ) -> [GuidePageSetting] {
        [
            .readOnly("requires_manual_action", label: NSLocalizedString("保存快照", comment: ""), value: { .bool(true) }),
            .string("snapshot_kind", label: NSLocalizedString("快照类型", comment: ""), allowedValues: ["database", "full"], get: {
                kind.wrappedValue.rawValue
            }, set: { if let value = SnapshotBuilder.BackupKind(rawValue: $0) { kind.wrappedValue = value } }),
            .bool("encrypted", label: NSLocalizedString("设置密码", comment: ""), get: { encrypted.wrappedValue }, set: { encrypted.wrappedValue = $0 }),
            .bool("strong_derivation", label: NSLocalizedString("高强度派生", comment: ""), get: { strongDerivation.wrappedValue }, set: { strongDerivation.wrappedValue = $0 }),
            .writeOnlyString("password", label: NSLocalizedString("密码", comment: ""), isConfigured: { !password.wrappedValue.isEmpty }, set: { password.wrappedValue = $0 }),
            .writeOnlyString("password_confirmation", label: NSLocalizedString("确认密码", comment: ""), isConfigured: { !confirmation.wrappedValue.isEmpty }, set: { confirmation.wrappedValue = $0 }),
            .bool("s3_enabled", label: NSLocalizedString("启用 S3/R2 保存", comment: ""), get: { AppConfigStore.shared.syncBackupS3Enabled }, set: { AppConfigStore.shared.syncBackupS3Enabled = $0 }),
            .readOnly("upload_state", label: NSLocalizedString("状态", comment: ""), value: {
                switch SnapshotUploadManager.shared.state {
                case .idle: return .string("idle")
                case .preparing: return .string("preparing")
                case .uploading: return .string("uploading")
                case .succeeded: return .string("succeeded")
                case .failed: return .string("failed")
                }
            }),
            .readOnly("upload_percentage", label: NSLocalizedString("上传进度", comment: ""), value: {
                if case .succeeded = SnapshotUploadManager.shared.state { return .int(100) }
                return .int(SnapshotUploadManager.shared.progress?.displayPercentage ?? 0)
            })
        ]
    }

    public static var storageSettings: [GuidePageSetting] {
        let store = AppConfigStore.shared
        return [
            .string("endpoint", label: NSLocalizedString("对象存储 Endpoint", comment: ""), get: { store.syncBackupUploadEndpoint }, set: { store.syncBackupUploadEndpoint = $0 }),
            .string("region", label: NSLocalizedString("auto 或 us-east-1", comment: ""), get: { store.syncBackupS3Region }, set: { store.syncBackupS3Region = $0 }),
            .string("bucket", label: NSLocalizedString("存储桶名称", comment: ""), get: { store.syncBackupS3Bucket }, set: { store.syncBackupS3Bucket = $0 }),
            .string("key_prefix", label: NSLocalizedString("备份路径前缀（可选）", comment: ""), get: { store.syncBackupS3KeyPrefix }, set: { store.syncBackupS3KeyPrefix = $0 }),
            .writeOnlyString("access_key_id", label: NSLocalizedString("Access Key ID", comment: ""), isConfigured: { !store.syncBackupS3AccessKeyID.isEmpty }, set: { store.syncBackupS3AccessKeyID = $0 }),
            .writeOnlyString("secret_access_key", label: NSLocalizedString("Secret Access Key", comment: ""), isConfigured: { !store.syncBackupS3SecretAccessKey.isEmpty }, set: { store.syncBackupS3SecretAccessKey = $0 }),
            .writeOnlyString("session_token", label: NSLocalizedString("Session Token（可选）", comment: ""), isConfigured: { !store.syncBackupS3SessionToken.isEmpty }, set: { store.syncBackupS3SessionToken = $0 })
        ]
    }
}
