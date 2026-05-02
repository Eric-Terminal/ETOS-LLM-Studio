// ============================================================================
// SessionListView+SessionFolderBrowserView.swift
// ============================================================================
// iOS 会话文件夹浏览器的状态、入口参数与基础视图声明。
// ============================================================================

import Foundation
import Shared
import SwiftUI


struct SessionFolderBrowserView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @EnvironmentObject var syncManager: WatchSyncManager
    @Environment(\.dismiss) var dismiss

    let folderID: UUID?
    let isRoot: Bool
    let createConversationAction: (() -> Void)?

    @State var editingSessionID: UUID?
    @State var draftSessionName: String = ""
    @State var sessionToDelete: ChatSession?
    @State var sessionInfo: SessionInfoPayload?
    @State var showGhostSessionAlert = false
    @State var ghostSession: ChatSession?

    @State var createFolderParentID: UUID?
    @State var createFolderName: String = ""
    @State var isShowingCreateFolderAlert = false

    @State var folderToRename: SessionFolder?
    @State var renameFolderName: String = ""
    @State var isShowingRenameFolderAlert = false

    @State var folderToDelete: SessionFolder?

    @State var isBatchSelecting = false
    @State var selectedSessionIDs: Set<UUID> = []
    @State var selectedFolderIDs: Set<UUID> = []
    @State var showBatchDeleteConfirm = false
    @State var searchText: String = ""
    @State var searchHits: [UUID: SessionHistorySearchHit] = [:]
    @State var isSearching: Bool = false
    @State var latestSearchToken: Int = 0
    @State var pendingSearchWorkItem: DispatchWorkItem?
    @State var sessionPageIndex: Int = 0
    @State var searchResultPageIndex: Int = 0

    let maxSessionsPerPage = 100
}
