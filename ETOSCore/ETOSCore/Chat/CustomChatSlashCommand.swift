// ============================================================================
// CustomChatSlashCommand.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义用户自定义的聊天斜杠命令及其数据库配置存储。
// ============================================================================

import Combine
import Foundation

public struct CustomChatSlashCommand: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var trigger: String
    public var prompt: String
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        trigger: String,
        prompt: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.trigger = trigger
        self.prompt = prompt
        self.updatedAt = updatedAt
    }

    public var invocation: String {
        "/\(trigger)"
    }
}

@MainActor
public final class CustomChatSlashCommandStore: ObservableObject {
    public static let shared = CustomChatSlashCommandStore()
    public nonisolated static let didChangeNotification = Notification.Name(
        "com.ETOS.customChatSlashCommands.didChange"
    )

    @Published public private(set) var commands: [CustomChatSlashCommand]

    private var appConfigNotificationObserver: NSObjectProtocol?
    private var persistenceTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var commandIDByTrigger: [String: UUID]

    public init() {
        commands = []
        commandIDByTrigger = [:]
        appConfigNotificationObserver = NotificationCenter.default.addObserver(
            forName: AppConfigStore.persistentStoreDidLoadNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
        reload()
    }

    deinit {
        persistenceTask?.cancel()
        reloadTask?.cancel()
        if let appConfigNotificationObserver {
            NotificationCenter.default.removeObserver(appConfigNotificationObserver)
        }
    }

    public func reload(notify: Bool = false) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.loadCommandsFromStore()
            }.value
            guard let self, !Task.isCancelled else { return }
            self.apply(loaded)
            if notify {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
        }
    }

    public func upsert(_ command: CustomChatSlashCommand) {
        var updated = commands
        if let index = updated.firstIndex(where: { $0.id == command.id }) {
            updated[index] = command
        } else {
            updated.append(command)
        }
        save(updated)
    }

    public func delete(id: UUID) {
        save(commands.filter { $0.id != id })
    }

    public func isTriggerAvailable(_ trigger: String, excluding commandID: UUID? = nil) -> Bool {
        let canonical = Self.canonicalTrigger(trigger)
        guard Self.isValidTrigger(canonical),
              !ChatSlashCommandParser.isReservedTrigger(canonical) else {
            return false
        }
        guard let existingCommandID = commandIDByTrigger[canonical] else { return true }
        return existingCommandID == commandID
    }

    public nonisolated static func canonicalTrigger(_ trigger: String) -> String {
        var normalized = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "/" {
            normalized.removeFirst()
        }
        return normalized.lowercased()
    }

    public nonisolated static func isValidTrigger(_ trigger: String) -> Bool {
        let canonical = canonicalTrigger(trigger)
        guard !canonical.isEmpty else { return false }
        return canonical.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    private func save(_ commands: [CustomChatSlashCommand]) {
        reloadTask?.cancel()
        let normalized = Self.normalizedCommands(commands)
        apply(normalized)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)

        let previousTask = persistenceTask
        persistenceTask = Task.detached(priority: .utility) {
            _ = await previousTask?.value
            guard !Task.isCancelled else { return }
            Self.persist(normalized)
        }
    }

    private func apply(_ commands: [CustomChatSlashCommand]) {
        commandIDByTrigger = Dictionary(
            uniqueKeysWithValues: commands.map { ($0.trigger, $0.id) }
        )
        self.commands = commands
    }

    private nonisolated static func loadCommandsFromStore() -> [CustomChatSlashCommand] {
        guard let raw = AppConfigStore.persistentSnapshot()[AppConfigKey.customChatSlashCommands.rawValue] as? String,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([CustomChatSlashCommand].self, from: data) else {
            return []
        }
        return normalizedCommands(decoded)
    }

    private nonisolated static func persist(_ commands: [CustomChatSlashCommand]) {
        guard let data = try? JSONEncoder().encode(commands),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        AppConfigStore.persistSynchronously(.text(raw), for: .customChatSlashCommands)
    }

    private nonisolated static func normalizedCommands(
        _ commands: [CustomChatSlashCommand]
    ) -> [CustomChatSlashCommand] {
        var seenTriggers = Set<String>()
        return commands.compactMap { command in
            let trigger = canonicalTrigger(command.trigger)
            let trimmedPrompt = command.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidTrigger(trigger),
                  !ChatSlashCommandParser.isReservedTrigger(trigger),
                  !trimmedPrompt.isEmpty,
                  seenTriggers.insert(trigger).inserted else {
                return nil
            }

            var normalized = command
            normalized.trigger = trigger
            return normalized
        }
    }
}
