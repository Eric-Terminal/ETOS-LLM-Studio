// ============================================================================
// LocalModelProviderBridge.swift
// ============================================================================
// ETOS LLM Studio
//
// 将本机权重记录投射为现有聊天系统可识别的 RunnableModel。
// ============================================================================

import Foundation

public enum LocalModelProviderBridge {
    public static let providerID = UUID(uuidString: "A129B884-B23B-4D9A-A536-3D141D64F6A8")!
    public static let apiFormat = "local-llama-cpp"

    public static var provider: Provider {
        Provider(
            id: providerID,
            name: NSLocalizedString("本地模型", comment: "Local model provider name"),
            baseURL: "local://llama-cpp",
            apiKeys: [],
            apiFormat: apiFormat
        )
    }

    public static func isLocalProvider(_ provider: Provider) -> Bool {
        provider.id == providerID || provider.apiFormat == apiFormat
    }

    public static func isLocalRunnableModel(_ model: RunnableModel?) -> Bool {
        guard let model else { return false }
        return isLocalProvider(model.provider)
    }

    public static func runnableModel(for record: LocalModelRecord) -> RunnableModel {
        let model = Model(
            id: record.id,
            modelName: record.modelName,
            displayName: record.sanitizedDisplayName,
            isActivated: record.isActivated,
            kind: .chat,
            inputModalities: [.text],
            outputModalities: [.text],
            capabilities: [.streaming]
        )
        return RunnableModel(provider: provider, model: model)
    }

    public static func runnableModels(from records: [LocalModelRecord]) -> [RunnableModel] {
        records.map(runnableModel(for:))
    }

    public static func localRecordID(from runnableModelID: String) -> UUID? {
        let prefix = "\(providerID.uuidString)-"
        guard runnableModelID.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(runnableModelID.dropFirst(prefix.count)))
    }
}
