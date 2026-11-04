import SwiftUI

public enum GuideContextCompressionSettingsSupport {
    public static var modelRoutingHelp: String {
        NSLocalizedString("context_compression.model_routing", value: "Automatic selection uses this conversation's preferred model, then the main chat model or the first available chat model. A manually selected model will not be replaced if it becomes unavailable. Attachment recognition may use other models.", comment: "压缩模型选择规则")
    }

    @MainActor
    public static func settings(
        sessionID: UUID,
        models: [RunnableModel],
        retainedRoundCount: Binding<Int>,
        modelIdentifier: Binding<String?>,
        focusInstruction: Binding<String>
    ) -> [GuidePageSetting] {
        [
            .readOnly("source_session", label: NSLocalizedString("会话", comment: ""), value: { .string(sessionID.uuidString) }),
            .readOnly("requires_manual_creation", label: NSLocalizedString("创建续聊会话", comment: ""), value: { .bool(true) }),
            .readOnly("model_routing", label: NSLocalizedString("压缩模型", comment: ""), value: { .string(modelRoutingHelp) }),
            .readOnly("available_models", label: NSLocalizedString("压缩模型", comment: ""), value: {
                .array(models.map { model in
                    .dictionary([
                        "id": .string(model.id),
                        "model": .string(model.model.displayName),
                        "provider": .string(model.provider.name)
                    ])
                })
            }),
            .string("retained_rounds", label: NSLocalizedString("保留最近原文", comment: ""), allowedValues: ["0", "2", "4", "6", "10"], get: {
                String(retainedRoundCount.wrappedValue)
            }, set: { value in
                if let count = Int(value) { retainedRoundCount.wrappedValue = count }
            }),
            .json("model", label: NSLocalizedString("压缩模型", comment: ""), schema: .dictionary(["type": .string("string")]), get: {
                .string(modelIdentifier.wrappedValue ?? "")
            }, normalize: { value in
                guard case .string(let identifier) = value,
                      identifier.isEmpty || models.contains(where: { $0.id == identifier }) else {
                    throw GuideError.invalidToolArguments
                }
                return value
            }, set: { value in
                guard case .string(let identifier) = value else { throw GuideError.invalidToolArguments }
                modelIdentifier.wrappedValue = identifier.isEmpty ? nil : identifier
            }),
            .string("focus", label: NSLocalizedString("额外侧重点（可选）", comment: ""), get: {
                focusInstruction.wrappedValue
            }, set: { focusInstruction.wrappedValue = $0 })
        ]
    }
}
