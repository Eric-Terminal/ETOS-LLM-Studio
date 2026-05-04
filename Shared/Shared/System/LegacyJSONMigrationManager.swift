import Foundation
import Combine

@MainActor
public final class LegacyJSONMigrationManager: ObservableObject {
    public static let shared = LegacyJSONMigrationManager()

    @Published public private(set) var status: Persistence.LegacyJSONMigrationStatus?
    @Published public private(set) var latestResult: Persistence.LegacyJSONMigrationResult?
    @Published public private(set) var progress: Persistence.LegacyJSONMigrationProgress?
    @Published public private(set) var isMigrating: Bool = false
    @Published public var isMigrationPromptPresented: Bool = false
    @Published public var isCleanupPromptPresented: Bool = false
    @Published public private(set) var errorMessage: String?

    private var refreshTask: Task<Void, Never>?
    private var migrationTask: Task<Void, Never>?

    private init() {}

    public func refreshStatus() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let latest = Persistence.legacyJSONMigrationStatus()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.status = latest
                if self.isMigrating {
                    return
                }
                if latest.requiresImportDecision {
                    self.isMigrationPromptPresented = true
                }
                if latest.requiresCleanupDecision {
                    self.isCleanupPromptPresented = true
                }
            }
        }
    }

    public func postponeMigrationPrompt() {
        isMigrationPromptPresented = false
    }

    public func keepLegacyJSONForNow() {
        isCleanupPromptPresented = false
    }

    public func startMigration() {
        guard !isMigrating else { return }
        errorMessage = nil
        isMigrationPromptPresented = false
        isMigrating = true
        progress = Persistence.LegacyJSONMigrationProgress(
            stage: .preparing,
            processedSessions: 0,
            totalSessions: status?.estimatedSessionCount ?? 0,
            importedMessages: 0,
            estimatedTotalBytes: status?.estimatedLegacyBytes ?? 0,
            processedBytes: 0,
            currentSessionName: nil
        )

        migrationTask?.cancel()
        migrationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Persistence.migrateLegacyJSONIncrementally(
                    shouldCleanupLegacyJSONAfterImport: false,
                    throttleInterval: 0.03,
                    progressHandler: { progress in
                        Task { @MainActor [weak self] in
                            self?.progress = progress
                        }
                    }
                )

                await MainActor.run {
                    self.latestResult = result
                    self.isMigrating = false
                }
                await MainActor.run {
                    self.refreshStatus()
                    if self.status?.requiresCleanupDecision == true {
                        self.isCleanupPromptPresented = true
                    }
                    NotificationCenter.default.post(name: .legacyJSONMigrationDidFinish, object: nil)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isMigrating = false
                    self.refreshStatus()
                }
            }
        }
    }

    public func cleanupLegacyJSONArtifacts() {
        guard !isMigrating else { return }
        errorMessage = nil
        isCleanupPromptPresented = false

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Persistence.cleanupLegacyJSONArtifactsAfterImport()
                await MainActor.run {
                    self.refreshStatus()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.refreshStatus()
                }
            }
        }
    }
}

public extension Notification.Name {
    static let legacyJSONMigrationDidFinish = Notification.Name("persistence.legacyJSONMigrationDidFinish")
}
