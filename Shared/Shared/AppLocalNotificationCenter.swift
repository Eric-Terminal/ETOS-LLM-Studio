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
}

public enum AppLocalNotificationRoute: String, Sendable {
    case dailyPulse
}

@MainActor
public final class AppLocalNotificationCenter: NSObject, ObservableObject {
    public static let shared = AppLocalNotificationCenter()

    @Published public private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published public private(set) var pendingRoute: AppLocalNotificationRoute?

    private static let routeUserInfoKey = "route"
    private static let kindUserInfoKey = "kind"
    private static let dayKeyUserInfoKey = "dayKey"

    private var didConfigure = false

    private override init() {
        super.init()
    }

    public func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true
        UNUserNotificationCenter.current().delegate = self
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

    public static func dailyPulseUserInfo(kind: String, dayKey: String? = nil) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            routeUserInfoKey: AppLocalNotificationRoute.dailyPulse.rawValue,
            kindUserInfoKey: kind
        ]
        if let dayKey, !dayKey.isEmpty {
            info[dayKeyUserInfoKey] = dayKey
        }
        return info
    }

    public static func notificationTargetsDailyPulse(userInfo: [AnyHashable: Any]) -> Bool {
        guard let route = userInfo[routeUserInfoKey] as? String else { return false }
        return route == AppLocalNotificationRoute.dailyPulse.rawValue
    }

    public func consumePendingRoute() -> AppLocalNotificationRoute? {
        let route = pendingRoute
        pendingRoute = nil
        return route
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
        completionHandler([.sound])
#else
        completionHandler([.sound])
#endif
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if Self.notificationTargetsDailyPulse(userInfo: response.notification.request.content.userInfo) {
            Task { @MainActor in
                AppLocalNotificationCenter.shared.pendingRoute = .dailyPulse
                NotificationCenter.default.post(name: .requestOpenDailyPulse, object: nil)
            }
        }
        completionHandler()
    }
}
#else
public extension Notification.Name {
    static let requestOpenDailyPulse = Notification.Name("com.ETOS.dailyPulse.requestOpen")
}

@MainActor
public final class AppLocalNotificationCenter: NSObject, ObservableObject {
    public static let shared = AppLocalNotificationCenter()

    private override init() {
        super.init()
    }
}
#endif
