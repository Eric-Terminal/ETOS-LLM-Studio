// ============================================================================
// ChatViewModelHistoryWindow.swift
// ============================================================================
// 历史窗口只负责可见消息范围与双向扩窗，不参与消息渲染状态同步。
// ============================================================================

import ETOSCore
import Foundation

extension ChatViewModel {
    var usesAutomaticHistoryWindow: Bool {
        automaticHistoryLoadingEnabled
    }

    var usesManualHistoryLoading: Bool {
        !automaticHistoryLoadingEnabled && lazyLoadMessageCount > 0
    }

    func updateDisplayedMessages() {
        ensureVisibleMessagesCachePrepared()
        ensureHistoryWindowPrepared()
        guard let historyWindow else {
            updateDisplayedStatesIfNeeded([])
            updateHistoryBoundaryState(for: ChatHistoryWindow(lowerBound: 0, upperBound: 0))
            return
        }

        let subset = ChatHistoryWindowSupport.messages(
            in: historyWindow,
            from: visibleMessagesCache
        )
        updateDisplayedStatesIfNeeded(subset)
        updateHistoryBoundaryState(for: historyWindow)
    }

    @discardableResult
    func loadMoreHistoryChunk(count: Int? = nil) -> Bool {
        guard !isHistoryFullyLoaded else { return false }
        ensureHistoryWindowPrepared()
        guard let historyWindow else { return false }
        let updated = ChatHistoryWindowSupport.expandingEarlier(
            historyWindow,
            in: visibleMessagesCache,
            weightedBatchSize: count ?? incrementalHistoryBatchSize,
            maximumWeightedCount: nil
        )
        guard updated != historyWindow else { return false }
        self.historyWindow = updated
        updateDisplayedMessages()
        return true
    }

    @discardableResult
    func loadMoreAutomaticHistoryIfNeeded(count: Int? = nil) -> Bool {
        guard usesAutomaticHistoryWindow, !isHistoryFullyLoaded else { return false }
        ensureHistoryWindowPrepared()
        guard let historyWindow else { return false }
        let updated = ChatHistoryWindowSupport.expandingEarlier(
            historyWindow,
            in: visibleMessagesCache,
            weightedBatchSize: count ?? automaticHistoryBatchSize,
            maximumWeightedCount: automaticHistoryMaximumWindowSize
        )
        guard updated != historyWindow else { return false }
        self.historyWindow = updated
        updateDisplayedMessages()
        return true
    }

    @discardableResult
    func loadMoreAutomaticLaterHistoryIfNeeded(count: Int? = nil) -> Bool {
        guard usesAutomaticHistoryWindow, !isLaterHistoryFullyLoaded else { return false }
        ensureHistoryWindowPrepared()
        guard let historyWindow else { return false }
        let updated = ChatHistoryWindowSupport.expandingLater(
            historyWindow,
            in: visibleMessagesCache,
            weightedBatchSize: count ?? automaticHistoryBatchSize,
            maximumWeightedCount: automaticHistoryMaximumWindowSize
        )
        guard updated != historyWindow else { return false }
        self.historyWindow = updated
        updateDisplayedMessages()
        return true
    }

    func historyWindowPosition(of messageID: UUID) -> ChatHistoryWindowPosition? {
        ensureVisibleMessagesCachePrepared()
        ensureHistoryWindowPrepared()
        guard let historyWindow else { return nil }
        return ChatHistoryWindowSupport.position(
            of: messageID,
            in: visibleMessagesCache,
            window: historyWindow
        )
    }

    func historyWindowDistance(to messageID: UUID) -> Int? {
        ensureVisibleMessagesCachePrepared()
        ensureHistoryWindowPrepared()
        guard let historyWindow else { return nil }
        return ChatHistoryWindowSupport.distance(
            to: messageID,
            in: visibleMessagesCache,
            window: historyWindow
        )
    }

    @discardableResult
    func shiftHistoryWindow(
        toward messageID: UUID,
        weightedBatchSize: Int,
        preservesCurrentWindowSize: Bool = false
    ) -> Bool {
        ensureVisibleMessagesCachePrepared()
        ensureHistoryWindowPrepared()
        guard let historyWindow,
              let position = ChatHistoryWindowSupport.position(
                of: messageID,
                in: visibleMessagesCache,
                window: historyWindow
              ) else {
            return false
        }

        let maximumWeightedCount = preservesCurrentWindowSize
            ? max(
                1,
                ChatHistoryWindowSupport.weightedCount(
                    in: visibleMessagesCache,
                    window: historyWindow
                )
            )
            : automaticHistoryMaximumWindowSize

        let updated: ChatHistoryWindow
        switch position {
        case .earlier:
            updated = ChatHistoryWindowSupport.expandingEarlier(
                historyWindow,
                in: visibleMessagesCache,
                weightedBatchSize: weightedBatchSize,
                maximumWeightedCount: maximumWeightedCount
            )
        case .later:
            updated = ChatHistoryWindowSupport.expandingLater(
                historyWindow,
                in: visibleMessagesCache,
                weightedBatchSize: weightedBatchSize,
                maximumWeightedCount: maximumWeightedCount
            )
        case .visible:
            return false
        }

        guard updated != historyWindow else { return false }
        self.historyWindow = updated
        updateDisplayedMessages()
        return true
    }

    @discardableResult
    func centerHistoryWindow(on messageID: UUID) -> Bool {
        ensureVisibleMessagesCachePrepared()
        guard let centeredWindow = ChatHistoryWindowSupport.centered(
            on: messageID,
            in: visibleMessagesCache,
            maximumWeightedCount: automaticHistoryMaximumWindowSize
        ), centeredWindow != historyWindow else {
            return false
        }
        historyWindow = centeredWindow
        updateDisplayedMessages()
        return true
    }

    func resetLazyLoadState() {
        historyWindow = nil
        updateDisplayedMessages()
    }

    /// 顶部导航直接切换到首个有界窗口，避免长会话逐段播放数十秒滚动动画。
    func moveHistoryWindowToStart() {
        ensureVisibleMessagesCachePrepared()
        let weightedLimit: Int
        if usesAutomaticHistoryWindow {
            weightedLimit = automaticHistoryMaximumWindowSize
        } else if usesManualHistoryLoading {
            weightedLimit = max(1, lazyLoadMessageCount)
        } else {
            weightedLimit = max(1, visibleMessagesCache.count)
        }
        historyWindow = ChatHistoryWindowSupport.leading(
            in: visibleMessagesCache,
            weightedLimit: weightedLimit
        )
        updateDisplayedMessages()
    }
}
