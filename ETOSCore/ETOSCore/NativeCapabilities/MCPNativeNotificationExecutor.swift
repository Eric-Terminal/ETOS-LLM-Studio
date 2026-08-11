// ============================================================================
// MCPNativeNotificationExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// 仅管理当前应用自己的本地通知；读取不会触发权限请求。
// ============================================================================

import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

actor MCPNativeNotificationExecutor {
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(UserNotifications)
        switch toolName {
        case "notifications.list_pending":
            return await listPending()
        case "notifications.schedule":
            return try await schedule(arguments)
        case "notifications.cancel":
            return try cancel(arguments)
        case "notifications.list_delivered":
            return await listDelivered()
        case "notifications.remove_delivered":
            return try removeDelivered(arguments)
        default:
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
        #else
        throw MCPNativeCapabilityError.unavailable(
            NSLocalizedString("当前平台没有 UserNotifications。", comment: "UserNotifications unavailable")
        )
        #endif
    }
}

#if canImport(UserNotifications)
private extension MCPNativeNotificationExecutor {
    func listPending() async -> [String: Any] {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return [
            "notifications": requests.map(requestPayload),
            "count": requests.count
        ]
    }

    func schedule(_ arguments: [String: Any]) async throws -> [String: Any] {
        try await ensureAuthorization()
        let title = try arguments.nativeRequiredString("title")
        let body = try arguments.nativeRequiredString("body")
        let identifier = arguments.nativeString("identifier") ?? UUID().uuidString
        let repeats = arguments.nativeBool("repeats") ?? false
        let trigger: UNNotificationTrigger

        if let fireDate = try arguments.nativeDate("fire_date") {
            guard arguments.nativeDouble("time_interval_seconds") == nil else {
                throw MCPNativeCapabilityError.invalidArgument(
                    NSLocalizedString("fire_date 与 time_interval_seconds 只能提供一个。", comment: "Notification trigger arguments conflict")
                )
            }
            guard !repeats else {
                throw MCPNativeCapabilityError.invalidArgument(
                    NSLocalizedString("重复通知请使用 time_interval_seconds。", comment: "Repeating date notification unsupported")
                )
            }
            let components = Calendar.current.dateComponents(
                [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else {
            let interval = arguments.nativeDouble("time_interval_seconds") ?? 1
            let minimum = repeats ? 60.0 : 1.0
            guard interval >= minimum else {
                throw MCPNativeCapabilityError.invalidArgument(
                    String(format: NSLocalizedString("通知延迟不得少于 %.0f 秒。", comment: "Notification interval too short"), minimum)
                )
            }
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: repeats)
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if arguments.nativeBool("sound") != false {
            content.sound = .default
        }
        content.userInfo = ["source": "etos_native_mcp"]
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
        return [
            "scheduled": true,
            "notification": requestPayload(request)
        ]
    }

    func cancel(_ arguments: [String: Any]) throws -> [String: Any] {
        let identifiers = try arguments.nativeRequiredStringArray("identifiers")
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        return ["cancelled": true, "identifiers": identifiers, "count": identifiers.count]
    }

    func listDelivered() async -> [String: Any] {
        let notifications = await UNUserNotificationCenter.current().deliveredNotifications()
        let payloads = notifications.map { notification in
            var payload = requestPayload(notification.request)
            payload["delivered_date"] = MCPBuiltInPersonalDataDateCodec.string(notification.date) ?? ""
            return payload
        }
        return ["notifications": payloads, "count": payloads.count]
    }

    func removeDelivered(_ arguments: [String: Any]) throws -> [String: Any] {
        let identifiers = try arguments.nativeRequiredStringArray("identifiers")
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        return ["removed": true, "identifiers": identifiers, "count": identifiers.count]
    }

    func ensureAuthorization() async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return
        case .notDetermined:
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                throw MCPNativeCapabilityError.permissionDenied(
                    NSLocalizedString("用户未授予通知权限。", comment: "Notification permission denied")
                )
            }
        case .denied:
            throw MCPNativeCapabilityError.permissionDenied(
                NSLocalizedString("通知权限已被拒绝。", comment: "Notification permission denied")
            )
        @unknown default:
            throw MCPNativeCapabilityError.permissionDenied(
                NSLocalizedString("未知通知权限状态。", comment: "Unknown notification permission")
            )
        }
    }

    func requestPayload(_ request: UNNotificationRequest) -> [String: Any] {
        let nextTriggerDate: Date?
        if let trigger = request.trigger as? UNCalendarNotificationTrigger {
            nextTriggerDate = trigger.nextTriggerDate()
        } else if let trigger = request.trigger as? UNTimeIntervalNotificationTrigger {
            nextTriggerDate = trigger.nextTriggerDate()
        } else {
            nextTriggerDate = nil
        }
        return [
            "identifier": request.identifier,
            "title": request.content.title,
            "subtitle": request.content.subtitle,
            "body": request.content.body,
            "badge": request.content.badge ?? NSNull(),
            "has_sound": request.content.sound != nil,
            "next_trigger_date": MCPBuiltInPersonalDataDateCodec.string(nextTriggerDate) ?? NSNull(),
            "repeats": request.trigger?.repeats ?? false
        ]
    }
}
#endif
