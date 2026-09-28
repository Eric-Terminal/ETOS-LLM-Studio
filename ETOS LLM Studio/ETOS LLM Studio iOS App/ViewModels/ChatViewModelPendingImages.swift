import ETOSCore
import Foundation
import UIKit

extension ChatViewModel {
    func addImageAttachment(_ image: UIImage, forSessionID sessionID: UUID?) async {
        await prepareImageAttachment(forSessionID: sessionID) {
            ImageAttachment.from(image: image)
        }
    }

    func addImageAttachment(data: Data, forSessionID sessionID: UUID?) async {
        await prepareImageAttachment(forSessionID: sessionID) {
            guard let image = UIImage(data: data) else { return nil }
            return ImageAttachment.from(image: image)
        }
    }

    /// 相册按选择顺序等待每次准备；编码完成也不能把旧会话的附件追加到新会话。
    func prepareImageAttachment(
        forSessionID sessionID: UUID?,
        makeAttachment: @escaping @Sendable () -> ImageAttachment?
    ) async {
        guard !Task.isCancelled, currentSession?.id == sessionID else { return }
        let preparation = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil as ImageAttachment? }
            return makeAttachment()
        }
        let attachment = await withTaskCancellationHandler {
            await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        guard !Task.isCancelled, currentSession?.id == sessionID, let attachment else { return }
        pendingImageAttachments.append(attachment)
    }
}
