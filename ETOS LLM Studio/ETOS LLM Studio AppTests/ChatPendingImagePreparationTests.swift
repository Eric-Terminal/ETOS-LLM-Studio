import Combine
import ETOSCore
import Foundation
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("待发送图片后台准备", .serialized)
@MainActor
struct ChatPendingImagePreparationTests {
    @Test("图片准备离开主线程，完成时仅向原会话追加且响应取消", arguments: ["完成", "切换会话", "取消"])
    func preparationHonorsSessionAndCancellation(outcome: String) async throws {
        let model = ChatViewModel(chatService: ChatService(adapters: [:]))
        model.cancellables.removeAll()
        let session = ChatSession(id: UUID(), name: "图片准备原会话")
        model.currentSession = session
        let existing = ImageAttachment(data: Data([1]), mimeType: "image/png", fileName: "existing.png")
        let incoming = ImageAttachment(data: Data([2]), mimeType: "image/png", fileName: "incoming.png")
        model.pendingImageAttachments = [existing]
        let entered = AsyncStream<Bool>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let work = Task {
            await model.prepareImageAttachment(forSessionID: session.id) {
                entered.continuation.yield(Thread.isMainThread)
                // 闸门只挡后台准备，让测试确定地在 await 中间切会话或取消。
                let result = release.wait(timeout: .now() + 5)
                #expect(result == .success)
                return incoming
            }
        }
        defer {
            release.signal()
            entered.continuation.finish()
            work.cancel()
        }
        var iterator = entered.stream.makeAsyncIterator()
        let nextValue: Bool? = await iterator.next()
        let ranOnMainThread: Bool = try #require(nextValue as Bool?)
        #expect(!ranOnMainThread)
        #expect(model.pendingImageAttachments.map(\.id) == [existing.id])
        if outcome == "切换会话" {
            model.currentSession = ChatSession(id: UUID(), name: "图片准备新会话")
        } else if outcome == "取消" {
            work.cancel()
        }
        release.signal()
        await work.value
        let expectedIDs = outcome == "完成" ? [existing.id, incoming.id] : [existing.id]
        #expect(model.pendingImageAttachments.map(\.id) == expectedIDs)
    }

    @Test("相机和相册数据入口串行准备 JPEG，顺序和原比例均保留")
    func imageAndDataInputsKeepOrderAndAspect() async throws {
        let model = ChatViewModel(chatService: ChatService(adapters: [:]))
        model.cancellables.removeAll()
        model.currentSession = ChatSession(id: UUID(), name: "图片导入顺序")
        let sessionID = model.currentSession?.id
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        let image = renderer.image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        }
        await model.addImageAttachment(image, forSessionID: sessionID)
        let first = try #require(model.pendingImageAttachments.first)
        await model.addImageAttachment(data: try #require(image.pngData()), forSessionID: sessionID)
        #expect(model.pendingImageAttachments.count == 2)
        #expect(model.pendingImageAttachments.first?.id == first.id)
        #expect(model.pendingImageAttachments.last?.id != first.id)
        for attachment in model.pendingImageAttachments {
            #expect(attachment.mimeType == "image/jpeg")
            #expect(attachment.thumbnailData == nil)
            let prepared = try #require(await DisplayImageLoader.shared.pendingAttachment(
                attachment, target: DisplayImageTarget(size: CGSize(width: 220, height: 180), scale: 3)
            ))
            #expect(prepared.image.size == CGSize(width: 240, height: 160))
        }
    }
}
