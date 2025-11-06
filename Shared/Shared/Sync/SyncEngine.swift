// ============================================================================
// SyncEngine.swift
// ============================================================================
// 负责根据选项收集同步数据并执行合并逻辑
// - 构建 SyncPackage 供跨设备传输
// - 解析并合并来自对端的数据，处理冲突与去重
// ============================================================================

import Foundation
import Combine

public enum SyncEngine {
    
    // MARK: - 打包导出
    
    /// 根据同步选项构建完整同步包
    public static func buildPackage(
        options: SyncOptions,
        chatService: ChatService = .shared
    ) -> SyncPackage {
        var providers: [Provider] = []
        var sessions: [SyncedSession] = []
        var backgrounds: [SyncedBackground] = []
        
        if options.contains(.providers) {
            providers = ConfigLoader.loadProviders()
        }
        
        if options.contains(.sessions) {
            let allSessions = chatService.chatSessionsSubject.value.filter { !$0.isTemporary }
            sessions = allSessions.map { session in
                let messages = Persistence.loadMessages(for: session.id)
                return SyncedSession(session: session, messages: messages)
            }
        }
        
        if options.contains(.backgrounds) {
            ConfigLoader.setupBackgroundsDirectory()
            let directory = ConfigLoader.getBackgroundsDirectory()
            let fileManager = FileManager.default
            if let fileURLs = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                backgrounds = fileURLs.compactMap { url in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return SyncedBackground(filename: url.lastPathComponent, data: data)
                }
            }
        }
        
        return SyncPackage(
            options: options,
            providers: providers,
            sessions: sessions,
            backgrounds: backgrounds
        )
    }
    
    // MARK: - 合并导入
    
    /// 将对端发来的同步包合并到本地数据
    @discardableResult
    public static func apply(
        package: SyncPackage,
        chatService: ChatService = .shared
    ) -> SyncMergeSummary {
        var summary = SyncMergeSummary.empty
        
        if package.options.contains(.providers) {
            let result = mergeProviders(package.providers, chatService: chatService)
            summary.importedProviders = result.imported
            summary.skippedProviders = result.skipped
        }
        
        if package.options.contains(.sessions) {
            let result = mergeSessions(package.sessions, chatService: chatService)
            summary.importedSessions = result.imported
            summary.skippedSessions = result.skipped
        }
        
        if package.options.contains(.backgrounds) {
            let result = mergeBackgrounds(package.backgrounds)
            summary.importedBackgrounds = result.imported
            summary.skippedBackgrounds = result.skipped
            if result.imported > 0 {
                NotificationCenter.default.post(name: .syncBackgroundsUpdated, object: nil)
            }
        }
        
        return summary
    }
    
    // MARK: - Providers
    
    private static func mergeProviders(
        _ incoming: [Provider],
        chatService: ChatService
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        
        var local = ConfigLoader.loadProviders()
        var imported = 0
        var skipped = 0
        
        for var provider in incoming {
            let hasSameID = local.firstIndex { $0.id == provider.id }
            let hasEquivalent = local.firstIndex { $0.isEquivalent(to: provider) }
            
            switch (hasSameID, hasEquivalent) {
            case (.some(let index), _):
                if local[index] == provider {
                    skipped += 1
                    continue
                }
                // ID 相同但内容不同，生成新副本避免覆盖
                provider.id = UUID()
                provider.models = provider.models.map {
                    var clone = $0
                    clone.id = UUID()
                    return clone
                }
                provider.name.append("（同步）")
                ConfigLoader.saveProvider(provider)
                local.append(provider)
                imported += 1
                
            case (nil, .some(_)):
                // 已存在等价配置，忽略
                skipped += 1
                
            case (nil, nil):
                ConfigLoader.saveProvider(provider)
                local.append(provider)
                imported += 1
            }
        }
        
        if imported > 0 {
            chatService.reloadProviders()
        }
        
        return (imported, skipped)
    }
    
    // MARK: - Sessions
    
    private static func mergeSessions(
        _ incoming: [SyncedSession],
        chatService: ChatService
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        
        var sessions = chatService.chatSessionsSubject.value
        var imported = 0
        var skipped = 0
        
        for payload in incoming {
            var session = payload.session
            session.isTemporary = false
            
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                let localMessages = Persistence.loadMessages(for: session.id)
                if sessions[index].isEquivalent(to: session) && localMessages.isContentEqual(to: payload.messages) {
                    skipped += 1
                    continue
                }
                
                // UUID 冲突但内容不同，新建会话避免覆盖
                session = makeSyncedCopy(from: session, nameSuffix: "（同步副本）")
            } else if let duplicate = sessions.first(where: { $0.isEquivalent(to: session) }) {
                let localMessages = Persistence.loadMessages(for: duplicate.id)
                if localMessages.isContentEqual(to: payload.messages) {
                    skipped += 1
                    continue
                }
                session = makeSyncedCopy(from: session, nameSuffix: "（同步冲突）")
            }
            
            // 写入消息文件
            Persistence.saveMessages(payload.messages, for: session.id)
            sessions.insert(session, at: 0)
            imported += 1
        }
        
        if imported > 0 {
            Persistence.saveChatSessions(sessions)
            chatService.chatSessionsSubject.send(sessions)
            if chatService.currentSessionSubject.value == nil {
                chatService.currentSessionSubject.send(sessions.first)
            }
        }
        
        return (imported, skipped)
    }
    
    // MARK: - Backgrounds
    
    private static func mergeBackgrounds(_ incoming: [SyncedBackground]) -> (imported: Int, skipped: Int) {
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
            
            // 若存在同名文件且内容不同，则生成新的文件名
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
                // 写入失败视为跳过，避免中断同步流程
                skipped += 1
            }
        }
        
        return (imported, skipped)
    }

    // MARK: - Helpers

    /// 创建带有新 UUID 的会话副本，并附加命名后缀
    private static func makeSyncedCopy(from session: ChatSession, nameSuffix: String) -> ChatSession {
        let updatedName = session.name + nameSuffix
        return ChatSession(
            id: UUID(),
            name: updatedName,
            topicPrompt: session.topicPrompt,
            enhancedPrompt: session.enhancedPrompt,
            isTemporary: false
        )
    }
}
