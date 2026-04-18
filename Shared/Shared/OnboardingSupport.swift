// ============================================================================
// OnboardingSupport.swift
// ============================================================================
// ETOS LLM Studio 新手教程共享支持
//
// 定义内容:
// - 教程 ID、场景访问 ID、场景提示 ID
// - 教程完成度快照
// - 教程进度与提示关闭状态持久化
// ============================================================================

import Foundation
import Combine

public enum OnboardingGuideID: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case interactionPrimer
    case firstProvider
    case firstChat
    case sessionManagement
    case toolCenterBasics

    public var id: String { rawValue }
}

public enum OnboardingSurfaceID: String, CaseIterable, Codable, Hashable, Sendable {
    case providerManagement
    case toolCenter
    case sessionManagement
    case chat
}

public enum OnboardingHintID: String, CaseIterable, Codable, Hashable, Sendable {
    case sessionList
    case chatMessages
    case providerList
    case toolCenter
}

public struct OnboardingChecklistSnapshot: Hashable, Sendable {
    public var hasVisitedProviderManagement: Bool
    public var hasProvider: Bool
    public var hasActivatedModel: Bool
    public var hasNonTemporarySession: Bool
    public var hasSentMessage: Bool
    public var hasVisitedToolCenter: Bool
    public var hasVisitedSessionManagement: Bool
    public var hasVisitedChat: Bool
    public var currentModelDisplayName: String?

    public init(
        hasVisitedProviderManagement: Bool = false,
        hasProvider: Bool = false,
        hasActivatedModel: Bool = false,
        hasNonTemporarySession: Bool = false,
        hasSentMessage: Bool = false,
        hasVisitedToolCenter: Bool = false,
        hasVisitedSessionManagement: Bool = false,
        hasVisitedChat: Bool = false,
        currentModelDisplayName: String? = nil
    ) {
        self.hasVisitedProviderManagement = hasVisitedProviderManagement
        self.hasProvider = hasProvider
        self.hasActivatedModel = hasActivatedModel
        self.hasNonTemporarySession = hasNonTemporarySession
        self.hasSentMessage = hasSentMessage
        self.hasVisitedToolCenter = hasVisitedToolCenter
        self.hasVisitedSessionManagement = hasVisitedSessionManagement
        self.hasVisitedChat = hasVisitedChat
        self.currentModelDisplayName = currentModelDisplayName
    }

    public static let empty = OnboardingChecklistSnapshot()

    public static func capture(
        providers: [Provider],
        sessions: [ChatSession],
        currentModel: RunnableModel?,
        visitedSurfaceIDs: Set<OnboardingSurfaceID>,
        hasSentMessage: Bool
    ) -> OnboardingChecklistSnapshot {
        OnboardingChecklistSnapshot(
            hasVisitedProviderManagement: visitedSurfaceIDs.contains(.providerManagement),
            hasProvider: !providers.isEmpty,
            hasActivatedModel: providers.contains { provider in
                provider.models.contains(where: \.isActivated)
            },
            hasNonTemporarySession: sessions.contains(where: { !$0.isTemporary }),
            hasSentMessage: hasSentMessage,
            hasVisitedToolCenter: visitedSurfaceIDs.contains(.toolCenter),
            hasVisitedSessionManagement: visitedSurfaceIDs.contains(.sessionManagement),
            hasVisitedChat: visitedSurfaceIDs.contains(.chat),
            currentModelDisplayName: currentModel?.model.displayName
        )
    }

    public func isSatisfied(for guideID: OnboardingGuideID) -> Bool {
        switch guideID {
        case .interactionPrimer:
            return false
        case .firstProvider:
            return hasVisitedProviderManagement && hasProvider && hasActivatedModel
        case .firstChat:
            return hasVisitedChat
                && currentModelDisplayName != nil
                && hasNonTemporarySession
                && hasSentMessage
        case .sessionManagement:
            return false
        case .toolCenterBasics:
            return hasVisitedToolCenter
        }
    }

    public static func loadHasSentMessage(for sessions: [ChatSession]) async -> Bool {
        let persistedSessionIDs = sessions
            .filter { !$0.isTemporary }
            .map(\.id)

        guard !persistedSessionIDs.isEmpty else { return false }

        return await Task.detached(priority: .userInitiated) {
            for sessionID in persistedSessionIDs {
                let messages = Persistence.loadMessages(for: sessionID)
                if messages.contains(where: { message in
                    switch message.role {
                    case .user, .assistant, .tool:
                        return true
                    case .system, .error:
                        return false
                    }
                }) {
                    return true
                }
            }
            return false
        }.value
    }
}

@MainActor
public final class OnboardingProgressStore: ObservableObject {
    public static let shared = OnboardingProgressStore()

    @Published public private(set) var seenGuideIDs: Set<OnboardingGuideID>
    @Published public private(set) var completedGuideIDs: Set<OnboardingGuideID>
    @Published public private(set) var dismissedHintIDs: Set<OnboardingHintID>
    @Published public private(set) var visitedSurfaceIDs: Set<OnboardingSurfaceID>

    private let userDefaults: UserDefaults

    private enum DefaultsKey {
        static let seenGuideIDs = "onboarding.seenGuideIDs"
        static let completedGuideIDs = "onboarding.completedGuideIDs"
        static let dismissedHintIDs = "onboarding.dismissedHintIDs"
        static let visitedSurfaceIDs = "onboarding.visitedSurfaceIDs"
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        seenGuideIDs = Self.loadSet(OnboardingGuideID.self, key: DefaultsKey.seenGuideIDs, userDefaults: userDefaults)
        completedGuideIDs = Self.loadSet(OnboardingGuideID.self, key: DefaultsKey.completedGuideIDs, userDefaults: userDefaults)
        dismissedHintIDs = Self.loadSet(OnboardingHintID.self, key: DefaultsKey.dismissedHintIDs, userDefaults: userDefaults)
        visitedSurfaceIDs = Self.loadSet(OnboardingSurfaceID.self, key: DefaultsKey.visitedSurfaceIDs, userDefaults: userDefaults)
    }

    public func hasSeenGuide(_ guideID: OnboardingGuideID) -> Bool {
        seenGuideIDs.contains(guideID)
    }

    public func isGuideCompleted(_ guideID: OnboardingGuideID) -> Bool {
        completedGuideIDs.contains(guideID)
    }

    public func isHintDismissed(_ hintID: OnboardingHintID) -> Bool {
        dismissedHintIDs.contains(hintID)
    }

    public func hasVisitedSurface(_ surfaceID: OnboardingSurfaceID) -> Bool {
        visitedSurfaceIDs.contains(surfaceID)
    }

    public func markGuideSeen(_ guideID: OnboardingGuideID) {
        guard seenGuideIDs.insert(guideID).inserted else { return }
        persist(seenGuideIDs, key: DefaultsKey.seenGuideIDs)
    }

    public func markGuideCompleted(_ guideID: OnboardingGuideID) {
        markGuideSeen(guideID)
        guard completedGuideIDs.insert(guideID).inserted else { return }
        persist(completedGuideIDs, key: DefaultsKey.completedGuideIDs)
    }

    public func dismissHint(_ hintID: OnboardingHintID) {
        guard dismissedHintIDs.insert(hintID).inserted else { return }
        persist(dismissedHintIDs, key: DefaultsKey.dismissedHintIDs)
    }

    public func markVisited(_ surfaceID: OnboardingSurfaceID) {
        guard visitedSurfaceIDs.insert(surfaceID).inserted else { return }
        persist(visitedSurfaceIDs, key: DefaultsKey.visitedSurfaceIDs)
    }

    private func persist<Value: RawRepresentable & Hashable>(_ values: Set<Value>, key: String) where Value.RawValue == String {
        userDefaults.set(values.map(\.rawValue).sorted(), forKey: key)
    }

    private static func loadSet<Value: RawRepresentable & Hashable>(
        _ type: Value.Type,
        key: String,
        userDefaults: UserDefaults
    ) -> Set<Value> where Value.RawValue == String {
        let rawValues = userDefaults.stringArray(forKey: key) ?? []
        return Set(rawValues.compactMap(Value.init(rawValue:)))
    }
}
