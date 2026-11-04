import Foundation

enum ProviderCompanionTransfer {
    enum TransferError: LocalizedError {
        case unavailableProvider

        var errorDescription: String? {
            NSLocalizedString("provider.transfer.unavailable", value: "No saved remote provider is available to send.", comment: "单个提供商发送失败")
        }
    }

    static func makeEnvelope(provider: Provider, now: Date = Date()) throws -> SyncEnvelopeV2 {
        guard !LocalModelProviderBridge.isLocalProvider(provider) else {
            throw TransferError.unavailableProvider
        }

        // 手动分享只携带这个提供商，不读取全库，也不推进全量同步基线或生成删除墓碑。
        let package = SyncPackage(
            options: [.providers],
            sourcePlatform: SyncEngine.currentPlatformName,
            providers: [provider]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let record = SyncRecordDescriptor(
            type: .provider,
            recordID: provider.id.uuidString,
            checksum: try encoder.encode(provider).sha256Hex,
            updatedAt: now
        )
        return SyncEnvelopeV2(
            exportedAt: now,
            manifest: SyncManifest(generatedAt: now, options: [.providers], records: [record]),
            delta: SyncDeltaPackage(generatedAt: now, options: [.providers], package: package)
        )
    }
}
