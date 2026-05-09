// ============================================================================
// SyncEnginePrimaryMerge.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载同步导入时的 Provider、会话与背景文件顶层合并入口。
// ============================================================================

import Foundation
import Combine

extension SyncEngine {
    // MARK: - Providers

    static func mergeProviders(
        _ incoming: [Provider],
        chatService: ChatService
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var local = ConfigLoader.loadProviders()
        var imported = 0
        var skipped = 0
        var didMutateProviderStore = false

        let localCompaction = compactProvidersByIdentity(local)
        if localCompaction.changed {
            for removedProvider in localCompaction.removedProviders {
                ConfigLoader.deleteProvider(removedProvider)
            }
            for updatedProvider in localCompaction.updatedProviders {
                ConfigLoader.saveProvider(updatedProvider)
            }
            local = localCompaction.providers
            didMutateProviderStore = true
        }

        let incomingProviders = compactProvidersByIdentity(incoming).providers

        for provider in incomingProviders {
            let incomingHash = computeProviderContentHash(provider)

            if let exactIndex = local.firstIndex(where: { computeProviderContentHash($0) == incomingHash }) {
                let mergedAPIKeys = mergeProviderAPIKeys(local[exactIndex].apiKeys, provider.apiKeys)
                if mergedAPIKeys == local[exactIndex].apiKeys {
                    skipped += 1
                } else {
                    local[exactIndex].apiKeys = mergedAPIKeys
                    ConfigLoader.saveProvider(local[exactIndex])
                    imported += 1
                    didMutateProviderStore = true
                }
                continue
            }

            if let candidateIndex = providerMergeCandidateIndex(for: provider, localProviders: local) {
                switch mergeProviderDeep(local[candidateIndex], with: provider) {
                case .unchanged(let mergedProvider):
                    local[candidateIndex] = mergedProvider
                    skipped += 1
                    continue
                case .merged(let mergedProvider):
                    local[candidateIndex] = mergedProvider
                    ConfigLoader.saveProvider(mergedProvider)
                    imported += 1
                    didMutateProviderStore = true
                    continue
                case .conflict:
                    guard providerMergeIdentity(local[candidateIndex]) == providerMergeIdentity(provider) else {
                        break
                    }
                    let conservativeResult = mergeProviderConservatively(
                        local[candidateIndex],
                        with: provider,
                        preferIncomingModelCapabilityShape: true
                    )
                    if conservativeResult.changed {
                        local[candidateIndex] = conservativeResult.provider
                        ConfigLoader.saveProvider(conservativeResult.provider)
                        imported += 1
                        didMutateProviderStore = true
                    } else {
                        skipped += 1
                    }
                    continue
                case .forked:
                    // Provider 不会产生分叉（只有 Session 才有时序分叉）
                    skipped += 1
                    continue
                }
            }

            var copied = provider
            copied = reassignProviderIdentifiersIfNeeded(copied, existingProviders: local)
            ConfigLoader.saveProvider(copied)
            local.append(copied)
            imported += 1
            didMutateProviderStore = true
        }

        if didMutateProviderStore {
            chatService.reloadProviders()
        }

        return (imported, skipped)
    }

    // MARK: - Sessions

    static func mergeSessions(
        _ incoming: [SyncedSession],
        chatService: ChatService
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var sessions = chatService.chatSessionsSubject.value
        var messagesBySessionID: [UUID: [ChatMessage]] = [:]
        var imported = 0
        var skipped = 0

        for payload in incoming {
            var session = payload.session
            session.isTemporary = false

            let incomingHash = computeSessionContentHash(session: session, messages: payload.messages)
            if containsSessionHash(
                incomingHash,
                sessions: sessions,
                messagesBySessionID: &messagesBySessionID
            ) {
                skipped += 1
                continue
            }

            if let candidateIndex = sessionMergeCandidateIndex(for: session, localSessions: sessions) {
                let localSession = sessions[candidateIndex]
                let localMessages = messagesForSession(
                    localSession.id,
                    cache: &messagesBySessionID
                )

                switch mergeSessionDeep(
                    localSession: localSession,
                    localMessages: localMessages,
                    incomingSession: session,
                    incomingMessages: payload.messages
                ) {
                case .unchanged((let mergedSession, let mergedMessages)):
                    sessions[candidateIndex] = mergedSession
                    messagesBySessionID[mergedSession.id] = mergedMessages
                    skipped += 1
                    continue
                case .merged((let mergedSession, let mergedMessages)):
                    sessions[candidateIndex] = mergedSession
                    messagesBySessionID[mergedSession.id] = mergedMessages
                    Persistence.saveMessages(mergedMessages, for: mergedSession.id)
                    imported += 1
                    continue
                case .forked((let forkedSession, let forkedMessages)):
                    // 真分叉：本地版本原地保留，远端克隆为带「同步分支」标签的独立会话
                    let branchSession = makeBranchSession(from: forkedSession)
                    Persistence.saveMessages(forkedMessages, for: branchSession.id)
                    sessions.insert(branchSession, at: 0)
                    messagesBySessionID[branchSession.id] = forkedMessages
                    imported += 1
                    continue
                case .conflict:
                    break
                }
            }

            if sessions.firstIndex(where: { $0.id == session.id }) != nil
                || sessions.first(where: { $0.isEquivalentIgnoringSyncSuffix(to: session) }) != nil {
                session = makeNewSession(from: session)
            }

            Persistence.saveMessages(payload.messages, for: session.id)
            sessions.insert(session, at: 0)
            messagesBySessionID[session.id] = payload.messages
            imported += 1
        }

        if imported > 0 {
            Persistence.saveChatSessions(sessions)
            chatService.chatSessionsSubject.send(sessions)
            if let current = chatService.currentSessionSubject.value,
               let updatedCurrent = sessions.first(where: { $0.id == current.id }) {
                chatService.currentSessionSubject.send(updatedCurrent)
            } else if chatService.currentSessionSubject.value == nil {
                chatService.currentSessionSubject.send(sessions.first)
            }
        }

        return (imported, skipped)
    }

    // MARK: - Backgrounds

    static func mergeBackgrounds(_ incoming: [SyncedBackground]) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        ConfigLoader.setupBackgroundsDirectory()
        let directory = ConfigLoader.getBackgroundsDirectory()
        let fileManager = FileManager.default
        var checksumMap: [String: URL] = [:]

        if let localFiles = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in localFiles {
                if let data = try? Data(contentsOf: url) {
                    checksumMap[data.sha256Hex] = url
                }
            }
        }

        var imported = 0
        var skipped = 0

        for background in incoming {
            if checksumMap[background.checksum] != nil {
                skipped += 1
                continue
            }

            var targetName = background.filename
            var targetURL = directory.appendingPathComponent(targetName)

            while fileManager.fileExists(atPath: targetURL.path) {
                let name = targetName.replacingOccurrences(of: ".\(targetURL.pathExtension)", with: "")
                targetName = "\(name)-sync-\(background.checksum.prefix(6)).\(targetURL.pathExtension)"
                targetURL = directory.appendingPathComponent(targetName)
            }

            do {
                try background.data.write(to: targetURL, options: [.atomic])
                checksumMap[background.checksum] = targetURL
                imported += 1
            } catch {
                skipped += 1
            }
        }

        return (imported, skipped)
    }
}
