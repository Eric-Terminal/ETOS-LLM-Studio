import Foundation

extension ChatMessage {
    /// 工具调用必须先完成其调用链；错误提示和附件占位不能充当助手正文前缀。
    public var canPrefill: Bool {
        role == .assistant && !content.isEmpty
            && (toolCalls?.isEmpty ?? true)
            && (imageFileNames?.isEmpty ?? true)
            && audioFileName == nil && (fileFileNames?.isEmpty ?? true)
    }
}

extension RunnableModel {
    public var canRequestAssistantPrefill: Bool {
        !LocalModelProviderBridge.isLocalRunnableModel(self) && !model.usesDedicatedImageGenerationEndpoint
    }
}
