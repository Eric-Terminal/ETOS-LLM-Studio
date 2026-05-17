// ============================================================================
// SessionFolderBrowserInteractions.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供 iOS 会话文件夹浏览器的弹窗、搜索结果、分页、行构造与批量操作。
// ============================================================================

import Foundation
import Shared
import SwiftUI

extension SessionFolderBrowserView {
    func applyStateHandlers<Content: View>(to content: Content) -> some View {
        let pagingContent = content
            .onChange(of: viewModel.sessionFolderListVersion) { _, _ in
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
                normalizeSessionPageIndex()
            }
            .onChange(of: totalSearchResultCount) { _, _ in
                normalizeSearchResultPageIndex()
            }

        let searchContent = pagingContent
            .onAppear {
                normalizeSessionPageIndex()
                normalizeSearchResultPageIndex()
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
                searchResultPageIndex = 0
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
        Section {
            if isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(NSLocalizedString("正在搜索历史会话…", comment: ""))
                        .foregroundStyle(.secondary)
                }
            } else if searchResultSessions.isEmpty {
                Text(NSLocalizedString("未找到匹配的搜索结果。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pagedSearchResultItems) { result in
                    searchResultRow(result)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.visible)
                }
            }
        } header: {
            Text(NSLocalizedString("搜索结果", comment: ""))
        } footer: {
            if !isSearching {
                Text(String(format: NSLocalizedString("匹配 %d 条结果 / %d 个会话", comment: ""), searchResultItems.count, searchResultSessions.count))
            }
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

    var paginationBar: some View {
        HStack(spacing: 10) {
            paginationButton(
                systemName: "chevron.left",
                accessibilityLabel: NSLocalizedString("上一页", comment: ""),
                isEnabled: canGoToPreviousActivePage,
                action: goToPreviousActivePage
            )

            paginationSummaryField

            paginationButton(
                systemName: "chevron.right",
                accessibilityLabel: NSLocalizedString("下一页", comment: ""),
                isEnabled: canGoToNextActivePage,
                action: goToNextActivePage
            )
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    var paginationSummaryField: some View {
        let field = Text(activePaginationSummaryText)
            .etFont(.callout)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)

        if #available(iOS 26.0, *) {
            field
                .glassEffect(.clear, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        } else {
            field
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Capsule()
                        .stroke(Color(uiColor: .separator).opacity(0.32), lineWidth: 0.5)
                )
        }
    }

    func paginationButton(
        systemName: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            Image(systemName: systemName)
                .etFont(.system(size: 17, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 44, height: 44)
                .background {
                    paginationButtonBackground
                        .frame(width: 44, height: 44)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    var paginationButtonBackground: some View {
        if #available(iOS 26.0, *) {
            Circle()
                .fill(Color.clear)
                .glassEffect(.clear, in: Circle())
                .overlay(
                    Circle()
                        .fill(Color(uiColor: .systemBackground).opacity(0.22))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.24), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
        } else {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Circle()
                        .stroke(Color(uiColor: .separator).opacity(0.32), lineWidth: 0.5)
                )
        }
    }

    func mergedEntryRow(_ entry: SessionMergedEntry) -> AnyView {
        switch entry {
        case .folder(let folder):
            return AnyView(folderRow(folder))
        case .session(let session):
            return AnyView(
                sessionRow(session)
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
                SessionListRowContent(
                    title: searchResultTitle(for: result),
                    subtitle: result.match.preview,
                    footnote: nil,
                    isCurrent: session.id == viewModel.currentSession?.id,
                    isRunning: viewModel.runningSessionIDs.contains(session.id)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    func folderLabel(for folder: SessionFolder) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(folder.name)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.accentColor)
                }
                .etFont(.system(size: 16, weight: .medium))

                let count = recursiveSessionCount(in: folder.id)
                Text(String(format: NSLocalizedString("%d 个会话", comment: ""), count))
                    .etFont(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
