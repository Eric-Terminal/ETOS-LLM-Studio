import ETOSCore
import Foundation

extension MacWorkspaceModel {
    func extractMarkdownImages(from original: ChatMessage, sessionID: UUID) async throws {
        guard canModifyCurrentHistory, currentSession?.id == sessionID, let service else { throw MessageToolCallEditingError.messageChanged }
        // 下载和保存附件属于历史写入，恢复与退出必须等待完整操作及失败清理。
        isMutatingHistory = true
        defer { isMutatingHistory = false; flushToolSupplements() }
        let result = await Task.detached(priority: .userInitiated) {
            await service.extractInlineImagesFromMarkdown(original.content)
        }.value
        guard !result.imageFileNames.isEmpty else { return }
        do {
            try Task.checkCancellation()
            guard currentSession?.id == sessionID, AppLockManager.shared.state != .locked else { throw MessageToolCallEditingError.messageChanged }
            var edited = original
            edited.content = result.cleanedContent
            edited.imageFileNames = (original.imageFileNames ?? []) + result.imageFileNames
            edited.modelExcludedImageFileNames = (original.modelExcludedImageFileNames ?? []) + result.imageFileNames
            try await service.updateEditedMessage(edited, original: original, targetSessionID: sessionID)
        } catch {
            await Task.detached(priority: .utility) {
                for name in result.imageFileNames { Persistence.deleteImage(fileName: name) }
            }.value
            throw error
        }
    }
}
