import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacChatMotionTests {
    @Test("视口分页保留重叠并限制在含安全区的首尾边界")
    func pagingUsesVisibleHeightAndInsets() {
        let viewport = MacChatViewport(offset: 900, contentHeight: 2000, containerHeight: 500,
            visibleHeight: 440, topInset: 20, bottomInset: 40)
        #expect(viewport.minimum == -20)
        #expect(viewport.maximum == 1540)
        #expect(viewport.page(down: false) == 504)
        #expect(viewport.page(down: true) == 1296)
        var top = viewport; top.offset = -20
        #expect(!top.canGoUp && top.canGoDown)
        #expect(top.page(down: false) == -20)
        var bottom = viewport; bottom.offset = 1540
        #expect(bottom.canGoUp && !bottom.canGoDown)
        #expect(bottom.page(down: true) == 1540)
    }

    @Test("不足一屏和初始零尺寸布局没有无效导航")
    func shortAndUnmeasuredContent() {
        let short = MacChatViewport(offset: -20, contentHeight: 100, containerHeight: 500,
            visibleHeight: 440, topInset: 20, bottomInset: 40)
        #expect(!short.canGoUp && !short.canGoDown)
        #expect(short.page(down: true) == -20)
        #expect(short.page(down: false) == -20)
        #expect(!MacChatViewport().canGoUp && !MacChatViewport().canGoDown)
    }

    @Test("生成导致内容增长仍跟随底部，单纯偏移变化不产生滚动反馈循环")
    func growthDoesNotDisableFollowing() {
        var state = MacChatFollowState()
        let old = MacChatViewport(offset: 500, contentHeight: 1000, containerHeight: 500,
            visibleHeight: 500, topInset: 0, bottomInset: 0)
        #expect(state.observe(old))
        let growing = MacChatViewport(offset: 500, contentHeight: 2000, containerHeight: 500,
            visibleHeight: 500, topInset: 0, bottomInset: 0)
        #expect(state.observe(growing))
        #expect(state.followsLatest)
        var moving = growing; moving.offset = 1100
        #expect(!state.observe(moving))
        #expect(state.followsLatest)
    }

    @Test("用户浏览历史解除跟随，回到底部附近释放后恢复")
    func userInteractionOwnsPosition() {
        var state = MacChatFollowState()
        var viewport = MacChatViewport(offset: 500, contentHeight: 1500, containerHeight: 500,
            visibleHeight: 500, topInset: 0, bottomInset: 0)
        _ = state.observe(viewport)
        #expect(!state.interaction(true))
        #expect(!state.followsLatest && state.isInteracting)
        #expect(!state.observe(viewport))
        #expect(!state.interaction(false))
        #expect(!state.followsLatest)
        _ = state.interaction(true)
        viewport.offset = 980
        _ = state.observe(viewport)
        #expect(state.interaction(false))
        #expect(state.followsLatest && !state.isInteracting)
    }

    @Test("程序翻页不会因进入空闲状态重新抢回底部")
    func explicitNavigationKeepsHistoryPosition() {
        var state = MacChatFollowState()
        state.navigate(toLatest: false)
        #expect(!state.interaction(false))
        #expect(!state.followsLatest)
        state.navigate(toLatest: true)
        #expect(state.followsLatest)
    }

    @Test("动画参数沿用范围，减弱动态或非手动滚动时不产生波浪位移")
    func motionSettingsRespectBoundsAndAccessibility() {
        let settings = MacChatMotionSettings(scrollEnabled: true, scrollOffset: 100, scrollResponse: -1,
            scrollDamping: 2, sendEnabled: true, sendResponse: 10, sendDamping: 0)
        #expect(settings.scrollOffset == 60 && settings.scrollResponse == 0.15 && settings.scrollDamping == 0.95)
        #expect(settings.sendResponse == 0.8 && settings.sendDamping == 0.4)
        #expect(settings.scrollTranslation(phase: -0.5, interacting: true, reduceMotion: false) == -30)
        #expect(settings.scrollTranslation(phase: 1, interacting: false, reduceMotion: false) == 0)
        #expect(settings.scrollTranslation(phase: 1, interacting: true, reduceMotion: true) == 0)
    }

    @Test("发送消息只认领一次，来源会话不符和未关联消息不能飞入")
    func sendBatchClaimsExactIdentityOnce() {
        let id = UUID(), session = UUID(), now = Date(timeIntervalSince1970: 100)
        var batch = MacSendMotionBatch(id: UUID(), sessionID: session, origin: CGPoint(x: 400, y: 700),
            deadline: now.addingTimeInterval(3), messageIDs: [id])
        let target = CGRect(x: 100, y: 300, width: 600, height: 100)
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(batch.claim(id, sessionID: UUID(), target: target, viewport: viewport, now: now) == nil)
        #expect(batch.claim(UUID(), sessionID: session, target: target, viewport: viewport, now: now) == nil)
        #expect(batch.claim(id, sessionID: session, target: target, viewport: viewport, now: now) == CGSize(width: 0, height: 350))
        #expect(batch.claim(id, sessionID: session, target: target, viewport: viewport, now: now) == nil)
    }

    @Test("过期、离屏及超过整屏的消息保持静止，附件身份独立")
    func sendBatchRejectsLateOrLargeContent() {
        let first = UUID(), second = UUID(), session = UUID(), now = Date(timeIntervalSince1970: 100)
        var batch = MacSendMotionBatch(id: UUID(), sessionID: session, origin: .zero,
            deadline: now.addingTimeInterval(3), messageIDs: [first, second])
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(batch.claim(first, sessionID: session, target: CGRect(x: 0, y: 900, width: 100, height: 100), viewport: viewport, now: now) == nil)
        #expect(batch.messageIDs.contains(first))
        #expect(batch.claim(first, sessionID: session, target: CGRect(x: 0, y: 0, width: 100, height: 900), viewport: viewport, now: now) == nil)
        #expect(!batch.messageIDs.contains(first) && batch.messageIDs.contains(second))
        #expect(batch.claim(second, sessionID: session, target: CGRect(x: 0, y: 0, width: 100, height: 100), viewport: viewport,
                            now: now.addingTimeInterval(3)) == nil)
    }

    @MainActor @Test("取消和下一次发送使旧 Core 身份回调失效")
    func cancelledBatchCannotBeReactivated() {
        let model = MacSendMotionModel(), session = UUID()
        let old = model.begin(sessionID: session, origin: .zero)
        let presentation = ChatSendPresentation(sessionID: session, messageIDsBySource: [.text: UUID()], responseGroupID: UUID())
        model.cancel()
        model.accept(presentation, for: old)
        #expect(model.batch == nil)
        let next = model.begin(sessionID: session, origin: CGPoint(x: 1, y: 2))
        model.accept(presentation, for: old)
        #expect(model.batch?.id == next)
        #expect(model.batch?.messageIDs.isEmpty == true)
        model.cancel()
    }

    @Test("双语向导说明立即保存、焦点按键与减少动态效果边界")
    func guideExplainsNavigationAndMotion() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh_CN")).content
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en_US")).content
        #expect(chinese.contains("Home/End/Page Up/Page Down") && chinese.contains("减少动态效果"))
        #expect(english.contains("Home/End/Page Up/Page Down") && english.contains("Reduce Motion"))
        #expect(english.contains("cannot scroll or send messages"))
    }
}
