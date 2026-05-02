// ============================================================================
// SessionListView+SessionFolderBrowserView.swift
// ============================================================================
// watchOS 会话文件夹浏览器的状态、入口参数与基础视图声明。
// ============================================================================

import Foundation
import Shared
import SwiftUI

/// 会话历史列表视图

struct SessionFolderBrowserView: View {
    let folderID: UUID?
    @Environment(\.colorScheme) var colorScheme

    @Binding var sessions: [ChatSession]
    @Binding var folders: [SessionFolder]
    @Binding var currentSession: ChatSession?
    let runningSessionIDs: Set<UUID>

    let deleteSessionAction: (ChatSession) -> Void
    let branchAction: (ChatSession, Bool) -> ChatSession?
    let deleteLastMessageAction: (ChatSession) -> Void
    let sendSessionToCompanionAction: (ChatSession) -> Void
    let onSessionSelected: (ChatSession, Int?) -> Void
    let updateSessionAction: (ChatSession) -> Void
    let createFolderAction: (String, UUID?) -> SessionFolder?
    let renameFolderAction: (SessionFolder, String) -> Void
    let deleteFolderAction: (SessionFolder) -> Void
    let moveSessionToFolderAction: (ChatSession, UUID?) -> Void
    let moveFolderToFolderAction: (SessionFolder, UUID?) -> Void
    let createConversationAction: (() -> Void)?
    let isRoot: Bool

    @Environment(\.dismiss) var dismiss

    @State var showDeleteSessionConfirm: Bool = false
    @State var sessionToDelete: ChatSession?
    @State var sessionToEdit: ChatSession?
    @State var showBranchOptions: Bool = false
    @State var sessionToBranch: ChatSession?

    @State var isShowingFolderEditor = false
    @State var folderEditorName: String = ""
    @State var folderEditorParentID: UUID?
    @State var folderBeingRenamed: SessionFolder?
    @State var folderToDelete: SessionFolder?
    @State var showMoreActions = false

    @State var isBatchSelecting = false
    @State var selectedSessionIDs: Set<UUID> = []
    @State var selectedFolderIDs: Set<UUID> = []
    @State var showBatchDeleteConfirm = false
    @State var showSessionSearch = false
    @State var sessionPageIndex: Int = 0

    let maxSessionsPerPage = 50
}
