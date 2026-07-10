// ============================================================================
// WatchContentViewMessageSelection.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 watchOS 聊天气泡多选与批量删除操作。
// ============================================================================

import Foundation
import WatchKit
import ETOSCore

extension ContentView {
    func beginMessageSelection(with message: ChatMessage) {
        isMessageSelectionMode = true
        selectedMessageIDs = [message.id]
        WKInterfaceDevice.current().play(.click)
    }

    func toggleMessageSelection(_ messageID: UUID) {
        if selectedMessageIDs.contains(messageID) {
            selectedMessageIDs.remove(messageID)
        } else {
            selectedMessageIDs.insert(messageID)
        }
        WKInterfaceDevice.current().play(.click)
    }

    func invertMessageSelection() {
        let selectableIDs = Set(viewModel.displayMessages.map(\.message.id))
        selectedMessageIDs = BatchSelectionSupport.invertedIDs(
            selectableIDs: selectableIDs,
            selectedIDs: selectedMessageIDs
        )
        WKInterfaceDevice.current().play(.click)
    }

    func exitMessageSelection() {
        isMessageSelectionMode = false
        selectedMessageIDs.removeAll()
        selectedMessagesExportTarget = nil
        showSelectedMessagesDeleteConfirm = false
    }

    func deleteSelectedMessages() {
        viewModel.deleteMessages(withIDs: selectedMessageIDs)
        exitMessageSelection()
    }
}
