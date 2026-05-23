// ============================================================================
// WatchContentViewSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承接 watchOS 主聊天视图的布局碎片、滚动控制、消息动作与迁移弹层。
// ============================================================================

import SwiftUI
import Foundation
import Shared

extension ContentView {
    var legacyChatRootView: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                chatList(proxy: proxy)

                if showScrollToBottomButton {
                    scrollToBottomButton(proxy: proxy)
                }
            }
        }
        .navigationTitle(viewModel.currentSession?.name ?? NSLocalizedString("新对话", comment: ""))
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(viewModel: viewModel, requestedDestination: $settingsDestination)
        }
        .sheet(item: $viewModel.activeSheet) { item in
            sheetView(for: item)
        }
        .sheet(item: Binding(
            get: { fullErrorContent.map { FullErrorContentWrapper(content: $0) } },
            set: { _ in fullErrorContent = nil }
        )) { wrapper in
            FullErrorContentView(content: wrapper.content)
        }
        .sheet(item: $viewModel.activeAskUserInputRequest) { request in
            WatchAskUserInputView(
                request: request,
                onSubmit: { answers in
                    viewModel.submitAskUserInputAnswers(answers, for: request)
                },
                onCancel: {
                    viewModel.cancelAskUserInputRequest(using: request)
                }
            )
        }
        .navigationDestination(item: $messageActionsTarget) { target in
            messageActionsView(for: target.id)
        }
        .alert(NSLocalizedString("数据库已自动恢复", comment: ""), isPresented: Binding(
            get: { launchRecoveryNoticeMessage != nil },
            set: { if !$0 { launchRecoveryNoticeMessage = nil } }
        )) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) { }
        } message: {
            Text(launchRecoveryNoticeMessage ?? "")
        }
        .sheet(isPresented: $announcementManager.shouldShowAlert) {
            if let announcement = announcementManager.currentAnnouncement {
                NavigationStack {
                    AnnouncementAlertView(
                        announcement: announcement,
                        onDismiss: {
                            announcementManager.dismissAlert()
                        }
                    )
                }
            }
        }
        .task {
            launchRecoveryNoticeMessage = Persistence.consumeLaunchRecoveryNotice()
            await announcementManager.checkAnnouncement()
            scheduleDailyPulsePreparation(after: 1_500_000_000)
            if applyDailyPulseContinuationIfNeeded() {
                return
            }
            if let pendingRoute = notificationCenter.consumePendingRoute() {
                switch pendingRoute {
                case .dailyPulse:
                    openDailyPulse()
                case .feedback:
                    openFeedbackFromNotification()
                case .chatSession:
                    openChatSessionFromNotification()
                case .achievementJournal:
                    openAchievementJournalFromNotification()
                case .updateTimeline:
                    openUpdateTimelineFromNotification()
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                ChatAppearanceProfileManager.shared.handleAppBecameActive()
                scheduleDailyPulsePreparation(after: 1_500_000_000)
            default:
                cancelDailyPulsePreparation()
            }
        }
    }

    @ViewBuilder
    var chatBackgroundLayer: some View {
        if viewModel.enableBackground,
           let bgImage = viewModel.currentBackgroundImageBlurredUIImage {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    if viewModel.backgroundContentMode == "fit" {
                        colorScheme == .dark ? Color.black : Color(white: 0.95)
                    }

                    Image(uiImage: bgImage)
                        .resizable()
                        .aspectRatio(contentMode: viewModel.backgroundContentMode == "fill" ? .fill : .fit)
                        .frame(width: size.width, height: size.height)
                        .position(x: size.width / 2, y: size.height / 2)
                        .clipped()
                        .opacity(viewModel.resolvedBackgroundOpacity)
                }
                .frame(width: size.width, height: size.height)
            }
        } else {
            Color.clear
        }
    }

    func memoryRetryStoppedNoticeBanner(text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .etFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            Text(text)
                .etFont(.footnote)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.memoryRetryStoppedNoticeMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .etFont(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("关闭提示", comment: ""))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    func sheetView(for item: ActiveSheet) -> some View {
        switch item {
        case .editMessage:
            if let messageToEdit = viewModel.messageToEdit {
                EditMessageView(message: messageToEdit, onSave: { updatedMessage in
                    viewModel.commitEditedMessage(updatedMessage)
                })
            }
        case .settings:
            SettingsView(viewModel: viewModel)
        @unknown default:
            Text(NSLocalizedString("未知视图", comment: ""))
        }
    }

    var sessionListView: some View {
        SessionListView(
            sessions: $viewModel.chatSessions,
            folders: $viewModel.sessionFolders,
            currentSession: $viewModel.currentSession,
            runningSessionIDs: viewModel.runningSessionIDs,
            deleteSessionAction: { session in
                viewModel.deleteSessions([session])
            },
            branchAction: { session, copyMessages in
                viewModel.branchSession(from: session, copyMessages: copyMessages)
            },
            deleteLastMessageAction: { session in
                viewModel.deleteLastMessage(for: session)
            },
            sendSessionToCompanionAction: { session in
                WatchSyncManager.shared.sendSessionToCompanion(sessionID: session.id)
            },
            onSessionSelected: { selectedSession, messageOrdinal in
                if let messageOrdinal {
                    viewModel.requestMessageJump(
                        sessionID: selectedSession.id,
                        messageOrdinal: messageOrdinal
                    )
                } else {
                    viewModel.clearPendingMessageJumpTarget()
                }
                ChatService.shared.setCurrentSession(selectedSession)
                isSessionListPresented = false
            },
            updateSessionAction: { session in
                viewModel.updateSession(session)
            },
            createFolderAction: { name, parentID in
                viewModel.createSessionFolder(name: name, parentID: parentID)
            },
            renameFolderAction: { folder, newName in
                viewModel.renameSessionFolder(folder, newName: newName)
            },
            deleteFolderAction: { folder in
                viewModel.deleteSessionFolder(folder)
            },
            moveSessionToFolderAction: { session, folderID in
                viewModel.moveSession(session, toFolderID: folderID)
            },
            moveFolderToFolderAction: { folder, parentID in
                viewModel.moveSessionFolder(folder, toParentID: parentID)
            },
            createConversationAction: {
                viewModel.createNewSession()
                isSessionListPresented = false
            }
        )
    }

    var legacyJSONMigrationPromptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("检测到旧版 JSON 数据", comment: ""))
                .etFont(.headline)
            Text(NSLocalizedString("建议立即迁移到 SQLite，后续版本可能不再支持旧格式。迁移会在后台分批执行，尽量避免卡顿。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)

            if let status = legacyJSONMigrationManager.status {
                Text(String(format: NSLocalizedString("预计 %.1f MB，约 %d 个会话", comment: ""), status.estimatedLegacyMegabytes, status.estimatedSessionCount))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button(NSLocalizedString("立即迁移（推荐）", comment: "")) {
                legacyJSONMigrationManager.startMigration()
            }
            .buttonStyle(.borderedProminent)

            Button(NSLocalizedString("稍后再说", comment: "")) {
                legacyJSONMigrationManager.postponeMigrationPrompt()
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .navigationTitle(NSLocalizedString("数据迁移", comment: ""))
    }

    var legacyJSONMigrationProgressSheet: some View {
        VStack(spacing: 10) {
            Text(NSLocalizedString("正在迁移", comment: ""))
                .etFont(.headline)
            if let progress = legacyJSONMigrationManager.progress {
                ProgressView(value: progress.fractionCompleted)
                Text(String(format: NSLocalizedString("会话 %d/%d", comment: ""), progress.processedSessions, max(progress.totalSessions, progress.processedSessions)))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                Text(String(format: NSLocalizedString("消息 %d", comment: ""), progress.importedMessages))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            Text(NSLocalizedString("迁移完成后会再询问是否删除旧 JSON。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .navigationTitle(NSLocalizedString("迁移中", comment: ""))
    }

    @ViewBuilder
    func messageActionsView(for messageID: UUID) -> some View {
        if let message = viewModel.allMessagesForSession.first(where: { $0.id == messageID }) {
            MessageActionsView(
                message: message,
                canRetry: viewModel.canRetry(message: message),
                onCopy: {
                    viewModel.applyToolInputDraftRequest(
                        AppToolInputDraftRequest(text: message.content, mode: .replace)
                    )
                },
                onEdit: {
                    viewModel.messageToEdit = message
                    viewModel.activeSheet = .editMessage
                },
                onRetry: { message in
                    viewModel.retryMessage(message)
                },
                onSpeak: { message in
                    viewModel.speakMessage(message)
                },
                onStopSpeaking: {
                    viewModel.stopSpeakingMessage()
                },
                onDelete: {
                    viewModel.deleteAllVersions(of: message)
                },
                onDeleteVersion: { index in
                    viewModel.deleteVersion(at: index, of: message)
                },
                onSwitchVersion: { index in
                    viewModel.switchToVersion(index, of: message)
                },
                onBranch: { copyPrompts in
                    _ = viewModel.branchSessionFromMessage(upToMessage: message, copyPrompts: copyPrompts)
                },
                onShowFullError: { content in
                    fullErrorContent = content
                },
                supportsMathRenderToggle: viewModel.enableAdvancedRenderer && (viewModel.preparedMarkdownByMessageID[message.id]?.containsMathContent ?? false),
                isMathRenderingEnabled: viewModel.isMathRenderingEnabled(for: message.id),
                onToggleMathRendering: {
                    viewModel.toggleMathRendering(for: message.id)
                },
                onJumpToMessageIndex: { displayIndex in
                    jumpToMessage(displayIndex: displayIndex)
                },
                session: viewModel.currentSession,
                allMessages: viewModel.allMessagesForSession,
                providers: viewModel.providers,
                messageIndex: viewModel.allMessagesForSession.firstIndex { $0.id == message.id },
                totalMessages: viewModel.allMessagesForSession.count
            )
        } else {
            EmptyView()
        }
    }

}
