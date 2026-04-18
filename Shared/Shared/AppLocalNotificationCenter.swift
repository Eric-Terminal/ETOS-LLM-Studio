// ============================================================================
// AppLocalNotificationCenter.swift
// ============================================================================
// ETOS LLM Studio 统一本地通知中心
//
// 功能特性:
// - 统一接管本地通知 delegate，避免多处覆盖导致路由失效
// - 提供通知权限查询、申请和通用通知投递入口
// - 负责解析 Daily Pulse 通知点击并广播页面跳转事件
// ============================================================================

import Foundation
import Combine

#if canImport(UserNotifications)
import UserNotifications

public extension Notification.Name {
    /// 请求当前设备直接打开 Daily Pulse 页面。
    static let requestOpenDailyPulse = Notification.Name("com.ETOS.dailyPulse.requestOpen")
    /// 请求当前设备直接进入 Daily Pulse 对应会话并填入继续聊提示词。
    static let requestContinueDailyPulseChat = Notification.Name("com.ETOS.dailyPulse.requestContinueChat")
    /// 请求当前设备直接打开反馈页面（可附带工单号）。
    static let requestOpenFeedback = Notification.Name("com.ETOS.feedback.requestOpen")
    /// 请求当前设备直接打开指定聊天会话。
    static let requestOpenChatSession = Notification.Name("com.ETOS.chat.requestOpenSession")
}

public enum AppLocalNotificationRoute: String, Sendable {
    case dailyPulse
    case feedback
    case chatSession
}

public struct AppLocalNotificationDailyPulseContinuation: Sendable, Equatable {
    public let sessionID: UUID
    public let prompt: String

    public init(sessionID: UUID, prompt: String) {
        self.sessionID = sessionID
        self.prompt = prompt
    }
}

private let appLocalNotificationRouteUserInfoKey = "route"
private let appLocalNotificationKindUserInfoKey = "kind"
private let appLocalNotificationDayKeyUserInfoKey = "dayKey"
private let appLocalNotificationRunIDUserInfoKey = "runID"
private let appLocalNotificationCardIDUserInfoKey = "cardID"
private let appLocalNotificationIssueNumberUserInfoKey = "issue_number"
private let appLocalNotificationSessionIDUserInfoKey = "session_id"
private let appLocalNotificationDailyPulseReminderCategoryIdentifier = "dailyPulse.reminder"
private let appLocalNotificationDailyPulseReadyCategoryIdentifier = "dailyPulse.ready"
private let appLocalNotificationDailyPulseOpenActionIdentifier = "dailyPulse.action.open"
private let appLocalNotificationDailyPulseLikeActionIdentifier = "dailyPulse.action.like"
private let appLocalNotificationDailyPulseSaveActionIdentifier = "dailyPulse.action.save"
private let appLocalNotificationDailyPulseContinueActionIdentifier = "dailyPulse.action.continue"
private let appLocalNotificationDailyPulseTaskActionIdentifier = "dailyPulse.action.task"

private struct AppLocalNotificationPayload: Sendable {
    let route: AppLocalNotificationRoute?
    let dayKey: String?
    let runID: UUID?
    let cardID: UUID?
    let issueNumber: Int?
    let sessionID: UUID?

    init(userInfo: [AnyHashable: Any]) {
        if let routeRawValue = userInfo[appLocalNotificationRouteUserInfoKey] as? String {
            route = AppLocalNotificationRoute(rawValue: routeRawValue)
        } else {
            route = nil
        }
        dayKey = userInfo[appLocalNotificationDayKeyUserInfoKey] as? String
        runID = (userInfo[appLocalNotificationRunIDUserInfoKey] as? String).flatMap(UUID.init(uuidString:))
        cardID = (userInfo[appLocalNotificationCardIDUserInfoKey] as? String).flatMap(UUID.init(uuidString:))
        issueNumber = AppLocalNotificationPayload.parseIssueNumber(from: userInfo)
        sessionID = (userInfo[appLocalNotificationSessionIDUserInfoKey] as? String).flatMap(UUID.init(uuidString:))
    }

    private static func parseIssueNumber(from userInfo: [AnyHashable: Any]) -> Int? {
        if let intValue = userInfo[appLocalNotificationIssueNumberUserInfoKey] as? Int {
            return intValue
        }
        if let numberValue = userInfo[appLocalNotificationIssueNumberUserInfoKey] as? NSNumber {
            return numberValue.intValue
        }
        if let stringValue = userInfo[appLocalNotificationIssueNumberUserInfoKey] as? String {
            return Int(stringValue)
        }
        return nil
    }
}

@MainActor
public final class AppLocalNotificationCenter: NSObject, ObservableObject {
    public static let shared = AppLocalNotificationCenter()

    @Published public private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published public private(set) var pendingRoute: AppLocalNotificationRoute?
    @Published public private(set) var pendingDailyPulseContinuation: AppLocalNotificationDailyPulseContinuation?
    @Published public private(set) var pendingFeedbackIssueNumber: Int?
    @Published public private(set) var pendingChatSessionID: UUID?

    private var didConfigure = false

    private override init() {
        super.init()
    }

    public func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()
        Task {
            await refreshAuthorizationStatus()
        }
    }

    @discardableResult
    public func refreshAuthorizationStatus() async -> UNAuthorizationStatus {
        configureIfNeeded()
        let settings = await currentNotificationSettings()
        authorizationStatus = settings.authorizationStatus
        return settings.authorizationStatus
    }

    @discardableResult
    public func requestAuthorizationIfNeeded(
        options: UNAuthorizationOptions = [.alert, .sound, .badge]
    ) async -> Bool {
        configureIfNeeded()
        let status = await refreshAuthorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            _ = await refreshAuthorizationStatus()
            return granted
        @unknown default:
            return false
        }
    }

    @discardableResult
    public func addNotificationRequest(_ request: UNNotificationRequest) async -> Bool {
        configureIfNeeded()
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    public func removePendingRequests(withIdentifiers identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func removeDeliveredRequests(withIdentifiers identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    public nonisolated static func dailyPulseUserInfo(
        kind: String,
        dayKey: String? = nil,
        runID: UUID? = nil,
        cardID: UUID? = nil
    ) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            appLocalNotificationRouteUserInfoKey: AppLocalNotificationRoute.dailyPulse.rawValue,
            appLocalNotificationKindUserInfoKey: kind
        ]
        if let dayKey, !dayKey.isEmpty {
            info[appLocalNotificationDayKeyUserInfoKey] = dayKey
        }
        if let runID {
            info[appLocalNotificationRunIDUserInfoKey] = runID.uuidString
        }
        if let cardID {
            info[appLocalNotificationCardIDUserInfoKey] = cardID.uuidString
        }
        return info
    }

    public nonisolated static func notificationTargetsDailyPulse(userInfo: [AnyHashable: Any]) -> Bool {
        guard let route = userInfo[appLocalNotificationRouteUserInfoKey] as? String else { return false }
        return route == AppLocalNotificationRoute.dailyPulse.rawValue
    }

    public nonisolated static func notificationTargetsFeedback(userInfo: [AnyHashable: Any]) -> Bool {
        guard let route = userInfo[appLocalNotificationRouteUserInfoKey] as? String else { return false }
        return route == AppLocalNotificationRoute.feedback.rawValue
    }

    public nonisolated static func notificationTargetsChatSession(userInfo: [AnyHashable: Any]) -> Bool {
        guard let route = userInfo[appLocalNotificationRouteUserInfoKey] as? String else { return false }
        return route == AppLocalNotificationRoute.chatSession.rawValue
    }

    public nonisolated static func dailyPulseCategoryIdentifier(kind: String) -> String {
        kind == "ready"
            ? appLocalNotificationDailyPulseReadyCategoryIdentifier
            : appLocalNotificationDailyPulseReminderCategoryIdentifier
    }

    public func consumePendingRoute() -> AppLocalNotificationRoute? {
        let route = pendingRoute
        pendingRoute = nil
        return route
    }

    public func consumePendingDailyPulseContinuation() -> AppLocalNotificationDailyPulseContinuation? {
        let continuation = pendingDailyPulseContinuation
        pendingDailyPulseContinuation = nil
        return continuation
    }

    public func consumePendingFeedbackIssueNumber() -> Int? {
        let issueNumber = pendingFeedbackIssueNumber
        pendingFeedbackIssueNumber = nil
        return issueNumber
    }

    public func consumePendingChatSessionID() -> UUID? {
        let sessionID = pendingChatSessionID
        pendingChatSessionID = nil
        return sessionID
    }

    private func registerNotificationCategories() {
        let openAction = UNNotificationAction(
            identifier: appLocalNotificationDailyPulseOpenActionIdentifier,
            title: "查看",
            options: [.foreground]
        )
        let likeAction = UNNotificationAction(
            identifier: appLocalNotificationDailyPulseLikeActionIdentifier,
            title: "喜欢",
            options: []
        )
        let saveAction = UNNotificationAction(
            identifier: appLocalNotificationDailyPulseSaveActionIdentifier,
            title: "保存为会话",
            options: []
        )
        let continueAction = UNNotificationAction(
            identifier: appLocalNotificationDailyPulseContinueActionIdentifier,
            title: "继续聊",
            options: [.foreground]
        )
        let taskAction = UNNotificationAction(
            identifier: appLocalNotificationDailyPulseTaskActionIdentifier,
            title: "加入任务",
            options: []
        )

        let reminderCategory = UNNotificationCategory(
            identifier: appLocalNotificationDailyPulseReminderCategoryIdentifier,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        let readyCategory = UNNotificationCategory(
            identifier: appLocalNotificationDailyPulseReadyCategoryIdentifier,
            actions: [likeAction, saveAction, continueAction, taskAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([reminderCategory, readyCategory])
    }

    private func dailyPulseTarget(from payload: AppLocalNotificationPayload) -> (runID: UUID, card: DailyPulseCard)? {
        return DailyPulseManager.shared.notificationTarget(
            runID: payload.runID,
            cardID: payload.cardID,
            dayKey: payload.dayKey
        )
    }

    private func openDailyPulseFromNotification() {
        pendingRoute = .dailyPulse
        NotificationCenter.default.post(name: .requestOpenDailyPulse, object: nil)
    }

    private func openFeedbackFromNotification(payload: AppLocalNotificationPayload) {
        pendingRoute = .feedback
        pendingFeedbackIssueNumber = payload.issueNumber
        NotificationCenter.default.post(name: .requestOpenFeedback, object: nil)
    }

    private func openChatSessionFromNotification(payload: AppLocalNotificationPayload) {
        pendingRoute = .chatSession
        pendingChatSessionID = payload.sessionID
        NotificationCenter.default.post(name: .requestOpenChatSession, object: nil)
    }

    private func continueDailyPulseFromNotification(payload: AppLocalNotificationPayload) {
        guard let target = dailyPulseTarget(from: payload),
              let session = DailyPulseManager.shared.saveCardAsSession(cardID: target.card.id, runID: target.runID) else {
            openDailyPulseFromNotification()
            return
        }

        ChatService.shared.setCurrentSession(session)
        pendingDailyPulseContinuation = AppLocalNotificationDailyPulseContinuation(
            sessionID: session.id,
            prompt: DailyPulseManager.defaultContinuationPrompt(for: target.card)
        )
        NotificationCenter.default.post(name: .requestContinueDailyPulseChat, object: nil)
    }

    func handleNotificationResponseUserInfo(
        _ userInfo: [AnyHashable: Any],
        actionIdentifier: String
    ) {
        let payload = AppLocalNotificationPayload(userInfo: userInfo)
        if payload.route == .dailyPulse {
            handleDailyPulseAction(
                actionIdentifier: actionIdentifier,
                payload: payload
            )
        } else if payload.route == .feedback {
            openFeedbackFromNotification(payload: payload)
        } else if payload.route == .chatSession {
            openChatSessionFromNotification(payload: payload)
        }
    }

    private func handleDailyPulseAction(
        actionIdentifier: String,
        payload: AppLocalNotificationPayload
    ) {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier, appLocalNotificationDailyPulseOpenActionIdentifier:
            openDailyPulseFromNotification()
        case appLocalNotificationDailyPulseLikeActionIdentifier:
            guard let target = dailyPulseTarget(from: payload) else { return }
            DailyPulseManager.shared.applyFeedback(.liked, cardID: target.card.id, runID: target.runID)
        case appLocalNotificationDailyPulseSaveActionIdentifier:
            guard let target = dailyPulseTarget(from: payload) else { return }
            _ = DailyPulseManager.shared.saveCardAsSession(cardID: target.card.id, runID: target.runID)
        case appLocalNotificationDailyPulseContinueActionIdentifier:
            continueDailyPulseFromNotification(payload: payload)
        case appLocalNotificationDailyPulseTaskActionIdentifier:
            guard let target = dailyPulseTarget(from: payload) else { return }
            _ = DailyPulseManager.shared.addTaskFromCard(cardID: target.card.id, runID: target.runID)
        default:
            break
        }
    }

    private func currentNotificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

}

extension AppLocalNotificationCenter: UNUserNotificationCenterDelegate {
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
#if os(iOS)
        completionHandler([.banner, .list, .sound])
#elseif os(watchOS)
        if #available(watchOS 8.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.sound])
        }
#else
        completionHandler([.sound])
#endif
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        Task { @MainActor [userInfo, actionIdentifier] in
            AppLocalNotificationCenter.shared.handleNotificationResponseUserInfo(
                userInfo,
                actionIdentifier: actionIdentifier
            )
        }
        completionHandler()
    }
}
#else
public extension Notification.Name {
    static let requestOpenDailyPulse = Notification.Name("com.ETOS.dailyPulse.requestOpen")
    static let requestOpenFeedback = Notification.Name("com.ETOS.feedback.requestOpen")
    static let requestOpenChatSession = Notification.Name("com.ETOS.chat.requestOpenSession")
}

@MainActor
public final class AppLocalNotificationCenter: NSObject, ObservableObject {
    public static let shared = AppLocalNotificationCenter()

    private override init() {
        super.init()
    }
}
#endif
