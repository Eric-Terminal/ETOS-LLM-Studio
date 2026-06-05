// ============================================================================
// SessionFolderBrowserInteractions.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供 iOS 会话文件夹浏览器的弹窗、搜索结果、无限滚动、行构造与批量操作。
// ============================================================================

import Foundation
import Shared
import SwiftUI

extension SessionFolderBrowserView {
    func applyStateHandlers<Content: View>(to content: Content) -> some View {
        let pagingContent = content
            .onChange(of: viewModel.sessionFolderListVersion) { _, _ in
                syncLoadedDirectSessionsWithSource()
                guard folderID != nil else { return }
                if currentFolder == nil {
                    dismiss()
                }
            }
            .onChange(of: pagedSessionIDs) { _, visibleIDs in
                selectedSessionIDs.formIntersection(Set(visibleIDs))
            }
            .onChange(of: childFolderIDs) { _, visibleIDs in
                selectedFolderIDs.formIntersection(Set(visibleIDs))
            }
            .onChange(of: totalDirectSessionCount) { _, _ in
                syncLoadedDirectSessionsWithSource()
            }
            .onChange(of: totalSearchResultCount) { _, _ in
                syncLoadedSearchResultItemsWithSource()
            }
            .onChange(of: viewModel.chatSessionListVersion) { _, _ in
                syncLoadedDirectSessionsWithSource()
            }

        let searchContent = pagingContent
            .onAppear {
                resetLoadedDirectSessions()
                resetLoadedSearchResultItems()
                guard isRoot else { return }
                scheduleSearch(for: searchText)
            }
            .onChange(of: searchText) { _, newValue in
                guard isRoot else { return }
                if !SessionHistorySearchSupport.normalizedQuery(newValue).isEmpty, isBatchSelecting {
                    isBatchSelecting = false
                    selectedSessionIDs.removeAll()
                    selectedFolderIDs.removeAll()
                }
                isLoadingMoreSearchResults = false
                loadedSearchResultItems = []
                scheduleSearch(for: newValue)
            }
            .onChange(of: viewModel.chatSessionListVersion) { _, _ in
                guard isRoot else { return }
                scheduleSearch(for: searchText)
            }
            .onChange(of: viewModel.currentSession?.id) { _, _ in
                guard isRoot else { return }
                scheduleSearch(for: searchText)
            }
            .onChange(of: viewModel.allMessageIdentityVersion) { _, _ in
                guard isRoot else { return }
                scheduleSearch(for: searchText)
            }

        return searchContent
            .onDisappear {
                pendingLoadMoreSessionsTask?.cancel()
                pendingLoadMoreSessionsTask = nil
                pendingLoadMoreSearchResultsTask?.cancel()
                pendingLoadMoreSearchResultsTask = nil
                isLoadingMoreSessions = false
                isLoadingMoreSearchResults = false
                guard isRoot else { return }
                pendingSearchWorkItem?.cancel()
                pendingSearchWorkItem = nil
            }
    }

    func applySessionAlerts<Content: View>(to content: Content) -> some View {
        content
            .alert(NSLocalizedString("确认删除会话", comment: ""), isPresented: Binding(
                get: { sessionToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        sessionToDelete = nil
                    }
                }
            )) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    if let session = sessionToDelete {
                        viewModel.deleteSessions([session])
                    }
                    sessionToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    sessionToDelete = nil
                }
            } message: {
                Text(NSLocalizedString("删除后所有消息也将被移除，操作不可恢复。", comment: ""))
            }
            .alert(NSLocalizedString("确认批量删除", comment: ""), isPresented: $showBatchDeleteConfirm) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    performBatchDelete()
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
            } message: {
                Text(batchDeleteMessage)
            }
    }

    func applyFolderEditingAlerts<Content: View>(to content: Content) -> some View {
        content
            .alert(NSLocalizedString("新建文件夹", comment: ""), isPresented: $isShowingCreateFolderAlert) {
                TextField(NSLocalizedString("文件夹名称", comment: ""), text: $createFolderName)
                Button(NSLocalizedString("创建", comment: "")) {
                    let trimmed = createFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    _ = viewModel.createSessionFolder(name: trimmed, parentID: createFolderParentID)
                    createFolderName = ""
                    createFolderParentID = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    createFolderName = ""
                    createFolderParentID = nil
                }
            } message: {
                if let createFolderParentID,
                   let parentFolder = folderByID[createFolderParentID] {
                    Text(String(format: NSLocalizedString("将在“%@”下创建子文件夹。", comment: ""), parentFolder.name))
                } else {
                    Text(NSLocalizedString("请输入新的文件夹名称。", comment: ""))
                }
            }
            .alert(NSLocalizedString("重命名文件夹", comment: ""), isPresented: $isShowingRenameFolderAlert) {
                TextField(NSLocalizedString("文件夹名称", comment: ""), text: $renameFolderName)
                Button(NSLocalizedString("保存", comment: "")) {
                    guard let folderToRename else { return }
                    let trimmed = renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    viewModel.renameSessionFolder(folderToRename, newName: trimmed)
                    self.folderToRename = nil
                    renameFolderName = ""
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    folderToRename = nil
                    renameFolderName = ""
                }
            } message: {
                Text(NSLocalizedString("请输入新的文件夹名称。", comment: ""))
            }
    }

    func applyDeleteFolderAlert<Content: View>(to content: Content) -> some View {
        content
            .alert(NSLocalizedString("确认删除文件夹", comment: ""), isPresented: Binding(
                get: { folderToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        folderToDelete = nil
                    }
                }
            )) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    if let folderToDelete {
                        viewModel.deleteSessionFolder(folderToDelete)
                    }
                    folderToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                    folderToDelete = nil
                }
            } message: {
                if let folderToDelete {
                    let descendantIDs = descendantFolderIDs(rootID: folderToDelete.id)
                    let folderCount = descendantIDs.count
                    let affectedSessions = viewModel.chatSessions.filter { session in
                        guard let assignedFolderID = normalizedFolderID(of: session) else { return false }
                        return descendantIDs.contains(assignedFolderID)
                    }.count
                    Text(String(format: NSLocalizedString("将删除 %d 个文件夹。%d 个会话将移回未分类。", comment: ""), folderCount, affectedSessions))
                }
            }
    }

    func applySheetAndGhostAlert<Content: View>(to content: Content) -> some View {
        content
            .sheet(item: $sessionInfo) { info in
                SessionInfoSheet(payload: info)
            }
            .alert(NSLocalizedString("发现幽灵会话", comment: ""), isPresented: $showGhostSessionAlert) {
                Button(NSLocalizedString("删除幽灵", comment: ""), role: .destructive) {
                    if let session = ghostSession {
                        viewModel.deleteSessions([session])
                    }
                    ghostSession = nil
                }
                Button(NSLocalizedString("稍后处理", comment: ""), role: .cancel) {
                    ghostSession = nil
                }
            } message: {
                Text(NSLocalizedString("这个会话的消息文件已经丢失了，只剩下一个空壳在这里游荡。\n\n要帮它超度吗？", comment: ""))
            }
    }

    func applySearchModifier<Content: View>(to content: Content) -> some View {
        if isRoot {
            return AnyView(
                content
                    .searchable(
                        text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text(NSLocalizedString("搜索会话标题或消息", comment: ""))
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            )
        }
        return AnyView(content)
    }

    @ViewBuilder
    var searchResultSection: some View {
        SessionGroupHeader(
            title: NSLocalizedString("搜索结果", comment: ""),
            systemImage: "magnifyingglass"
        )
        .padding(.top, 10)
        .padding(.bottom, 4)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)

        if isSearching {
            HStack(spacing: 8) {
                ProgressView()
                Text(NSLocalizedString("正在搜索历史会话…", comment: ""))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 16)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } else if searchResultSessions.isEmpty {
            Text(NSLocalizedString("未找到匹配的搜索结果。", comment: ""))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else {
            ForEach(pagedSearchResultItems) { result in
                searchResultRow(result)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onAppear {
                        loadMoreSearchResultItemsIfNeeded(currentID: result.id)
                    }
            }

            if shouldShowLoadingMoreFooter {
                loadingMoreFooter
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Text(String(format: NSLocalizedString("匹配 %d 条结果 / %d 个会话", comment: ""), searchResultItems.count, searchResultSessions.count))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    var batchActionBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button {
                    applyBatchMove(toFolderID: nil)
                } label: {
                    Label(NSLocalizedString("未分类", comment: ""), systemImage: "tray")
                }

                ForEach(batchMoveFolderOptions) { option in
                    Button {
                        applyBatchMove(toFolderID: option.id)
                    } label: {
                        Label(option.title, systemImage: "folder")
                    }
                }
            } label: {
                Label(NSLocalizedString("移动", comment: ""), systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!hasBatchSelection)

            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!hasBatchSelection)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    func mergedEntryRow(_ entry: SessionMergedEntry) -> AnyView {
        switch entry {
        case .folder(let folder):
            return AnyView(folderRow(folder))
        case .session(let session):
            return AnyView(
                sessionRow(session)
                    .onAppear {
                        loadMoreDirectSessionsIfNeeded(currentID: session.id)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if !isBatchSelecting {
                            Button(role: .destructive) {
                                sessionToDelete = session
                            } label: {
                                Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                            }
                        }
                    }
            )
        }
    }

    @ViewBuilder
    func folderRow(_ folder: SessionFolder) -> some View {
        if isBatchSelecting {
            BatchSelectableFolderRow(
                folder: folder,
                sessionCount: recursiveSessionCount(in: folder.id),
                isSelected: selectedFolderIDs.contains(folder.id),
                onToggle: {
                    toggleFolderSelection(folder.id)
                }
            )
        } else {
            NavigationLink {
                SessionFolderBrowserView(
                    folderID: folder.id,
                    isRoot: false,
                    createConversationAction: createConversationAction
                )
            } label: {
                folderLabel(for: folder)
            }
            .contextMenu {
                Button {
                    startRenaming(folder)
                } label: {
                    Label(NSLocalizedString("重命名文件夹", comment: ""), systemImage: "pencil")
                }

                Button(role: .destructive) {
                    folderToDelete = folder
                } label: {
                    Label(NSLocalizedString("删除文件夹", comment: ""), systemImage: "trash")
                }
            }
        }
    }

    var sessionListActionsMenu: some View {
        Menu {
            if let createConversationAction {
                Button {
                    createConversationAction()
                } label: {
                    Label(NSLocalizedString("新建对话", comment: ""), systemImage: "plus.message")
                }
            }

            Button {
                presentCreateFolder(parentID: folderID)
            } label: {
                Label(folderID == nil ? NSLocalizedString("新建文件夹", comment: "") : NSLocalizedString("新建子文件夹", comment: ""), systemImage: "folder.badge.plus")
            }

            Button {
                toggleBatchMode()
            } label: {
                Label(
                    isBatchSelecting ? NSLocalizedString("结束批量选择", comment: "") : NSLocalizedString("批量选择", comment: ""),
                    systemImage: isBatchSelecting ? "checkmark.circle.fill" : "pencil"
                )
            }
            .disabled(isSearchActive)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    func sessionRow(
        _ session: ChatSession,
        forceRegularMode: Bool = false,
        searchSummary: String? = nil,
        locationSummary: String? = nil
    ) -> some View {
        if isBatchSelecting && !forceRegularMode {
            BatchSelectableSessionRow(
                session: session,
                isSelected: selectedSessionIDs.contains(session.id),
                onToggle: {
                    toggleSessionSelection(session.id)
                }
            )
        } else {
            SessionRow(
                session: session,
                isCurrent: session.id == viewModel.currentSession?.id,
                isRunning: viewModel.runningSessionIDs.contains(session.id),
                isEditing: editingSessionID == session.id,
                draftName: editingSessionID == session.id ? $draftSessionName : .constant(session.name),
                currentFolderID: normalizedFolderID(of: session),
                moveOptions: moveFolderOptions,
                searchSummary: searchSummary,
                locationSummary: locationSummary,
                onCommit: { newName in
                    viewModel.updateSessionName(session, newName: newName)
                    editingSessionID = nil
                },
                onSelect: {
                    selectSession(session)
                },
                onRename: {
                    editingSessionID = session.id
                    draftSessionName = session.name
                },
                onBranch: { copyHistory in
                    let newSession = viewModel.branchSession(from: session, copyMessages: copyHistory)
                    viewModel.setCurrentSession(newSession)
                    focusOnLatest()
                },
                onMoveToFolder: { targetFolderID in
                    viewModel.moveSession(session, toFolderID: targetFolderID)
                },
                onDeleteLastMessage: {
                    viewModel.deleteLastMessage(for: session)
                },
                onDelete: {
                    sessionToDelete = session
                },
                onCancelRename: {
                    editingSessionID = nil
                    draftSessionName = session.name
                },
                onInfo: {
                    sessionInfo = SessionInfoPayload(
                        session: session,
                        messageCount: viewModel.messageCount(for: session),
                        isCurrent: session.id == viewModel.currentSession?.id
                    )
                },
                onSendToCompanion: {
                    syncManager.sendSessionToCompanion(sessionID: session.id)
                }
            )
        }
    }

    @ViewBuilder
    func searchResultRow(_ result: SessionHistorySearchResult) -> some View {
        if let session = viewModel.chatSessions.first(where: { $0.id == result.sessionID }) {
            Button {
                selectSession(session, messageOrdinal: result.messageOrdinal)
            } label: {
                SessionRowCard(isCurrent: session.id == viewModel.currentSession?.id) {
                    SessionSearchResultRowContent(
                        title: searchResultTitle(for: result),
                        preview: result.match.preview,
                        isCurrent: session.id == viewModel.currentSession?.id,
                        isRunning: viewModel.runningSessionIDs.contains(session.id)
                    )
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    func folderLabel(for folder: SessionFolder) -> some View {
        SessionRowCard(isCurrent: false) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(folder.name)
                        .etFont(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                let count = recursiveSessionCount(in: folder.id)
                Text(String(format: NSLocalizedString("%d 个会话", comment: ""), count))
                    .etFont(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    func toggleBatchMode() {
        isBatchSelecting.toggle()
        if !isBatchSelecting {
            selectedSessionIDs.removeAll()
            selectedFolderIDs.removeAll()
        }
    }

    func toggleSessionSelection(_ sessionID: UUID) {
        if selectedSessionIDs.contains(sessionID) {
            selectedSessionIDs.remove(sessionID)
        } else {
            selectedSessionIDs.insert(sessionID)
        }
    }

    func toggleFolderSelection(_ folderID: UUID) {
        if selectedFolderIDs.contains(folderID) {
            selectedFolderIDs.remove(folderID)
        } else {
            selectedFolderIDs.insert(folderID)
        }
    }

    func applyBatchMove(toFolderID folderID: UUID?) {
        for session in selectedSessions {
            viewModel.moveSession(session, toFolderID: folderID)
        }
        for folder in selectedFolders {
            viewModel.moveSessionFolder(folder, toParentID: folderID)
        }
        selectedSessionIDs.removeAll()
        selectedFolderIDs.removeAll()
    }

    func isValidBatchMoveTarget(_ targetFolderID: UUID) -> Bool {
        for selectedFolderID in selectedFolderIDs {
            if targetFolderID == selectedFolderID {
                return false
            }
            if folderHierarchyContains(descendantFolderID: targetFolderID, ancestorFolderID: selectedFolderID) {
                return false
            }
        }
        return true
    }

    func performBatchDelete() {
        let sessions = selectedSessions
        let folders = selectedFolders
        guard !sessions.isEmpty || !folders.isEmpty else { return }
        if !sessions.isEmpty {
            viewModel.deleteSessions(sessions)
        }
        folders.forEach { viewModel.deleteSessionFolder($0) }
        selectedSessionIDs.removeAll()
        selectedFolderIDs.removeAll()
    }

    var batchDeleteMessage: String {
        let folderText = selectedFolderIDs.isEmpty ? "" : String(format: NSLocalizedString("%d 个文件夹", comment: ""), selectedFolderIDs.count)
        let sessionText = selectedSessionIDs.isEmpty ? "" : String(format: NSLocalizedString("%d 个会话", comment: ""), selectedSessionIDs.count)
        let targetText = [folderText, sessionText]
            .filter { !$0.isEmpty }
            .joined(separator: NSLocalizedString("和", comment: ""))
        let targetSummary = targetText.isEmpty ? NSLocalizedString("所选项目", comment: "") : targetText
        return String(format: NSLocalizedString("将删除 %@。文件夹内的会话会移回未分类，操作不可恢复。", comment: ""), targetSummary)
    }
}
