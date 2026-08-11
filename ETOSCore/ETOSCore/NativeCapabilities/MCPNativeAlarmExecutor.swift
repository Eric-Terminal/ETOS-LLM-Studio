// ============================================================================
// MCPNativeAlarmExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// AlarmKit 是唯一闹钟后端；不可用时明确报错，不以普通通知伪装闹钟。
// ============================================================================

import Foundation
#if canImport(AlarmKit) && os(iOS)
import AlarmKit
import SwiftUI
#endif

actor MCPNativeAlarmExecutor {
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if os(watchOS)
        return try await MCPNativeDeviceCompanionRelay.shared.execute(
            toolName: toolName,
            arguments: arguments
        )
        #elseif canImport(AlarmKit) && os(iOS)
        guard #available(iOS 26.0, *) else {
            throw unavailableError
        }
        switch toolName {
        case "alarms.list":
            return try list()
        case "alarms.schedule":
            return try await schedule(arguments)
        case "alarms.cancel":
            return try cancel(arguments)
        default:
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
        #else
        throw unavailableError
        #endif
    }

    private var unavailableError: MCPNativeCapabilityError {
        .unavailable(
            NSLocalizedString("AlarmKit 在当前设备或系统版本不可用；ETOS 不会把闹钟降级为普通通知。", comment: "AlarmKit unavailable without fallback")
        )
    }
}

#if canImport(AlarmKit) && os(iOS)
@available(iOS 26.0, *)
private extension MCPNativeAlarmExecutor {
    func list() throws -> [String: Any] {
        let alarms = try AlarmManager.shared.alarms
        return ["alarms": alarms.map(payload), "count": alarms.count, "backend": "AlarmKit"]
    }

    func schedule(_ arguments: [String: Any]) async throws -> [String: Any] {
        let title = try arguments.nativeRequiredString("title")
        let fireDate = try arguments.nativeRequiredDate("fire_date")
        guard fireDate > Date() else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("闹钟时间必须晚于当前时间。", comment: "Alarm fire date must be future")
            )
        }
        let identifier: UUID
        if let rawIdentifier = arguments.nativeString("identifier") {
            guard let value = UUID(uuidString: rawIdentifier) else {
                throw MCPNativeCapabilityError.invalidArgument(
                    NSLocalizedString("identifier 必须是 UUID。", comment: "Invalid alarm UUID")
                )
            }
            identifier = value
        } else {
            identifier = UUID()
        }

        let manager = AlarmManager.shared
        switch manager.authorizationState {
        case .authorized:
            break
        case .notDetermined:
            guard try await manager.requestAuthorization() == .authorized else {
                throw MCPNativeCapabilityError.permissionDenied(
                    NSLocalizedString("用户未授予闹钟权限。", comment: "Alarm permission denied")
                )
            }
        case .denied:
            throw MCPNativeCapabilityError.permissionDenied(
                NSLocalizedString("闹钟权限已被拒绝。", comment: "Alarm permission denied")
            )
        @unknown default:
            throw MCPNativeCapabilityError.permissionDenied(
                NSLocalizedString("未知闹钟权限状态。", comment: "Unknown alarm permission")
            )
        }

        let titleResource = LocalizedStringResource(stringLiteral: title)
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: titleResource)
        } else {
            let stopButton = AlarmButton(
                text: LocalizedStringResource(stringLiteral: NSLocalizedString("停止", comment: "Alarm stop button")),
                textColor: .white,
                systemImageName: "stop.fill"
            )
            alert = AlarmPresentation.Alert(title: titleResource, stopButton: stopButton)
        }
        let presentation = AlarmPresentation(alert: alert)
        let attributes = AlarmAttributes<ETOSAlarmMetadata>(
            presentation: presentation,
            metadata: ETOSAlarmMetadata(title: title),
            tintColor: .orange
        )
        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule: .fixed(fireDate),
            attributes: attributes
        )
        let alarm = try await manager.schedule(id: identifier, configuration: configuration)
        return ["scheduled": true, "alarm": payload(alarm), "backend": "AlarmKit"]
    }

    func cancel(_ arguments: [String: Any]) throws -> [String: Any] {
        let rawIdentifier = try arguments.nativeRequiredString("identifier")
        guard let identifier = UUID(uuidString: rawIdentifier) else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("identifier 必须是 UUID。", comment: "Invalid alarm UUID")
            )
        }
        try AlarmManager.shared.cancel(id: identifier)
        return ["cancelled": true, "identifier": identifier.uuidString, "backend": "AlarmKit"]
    }

    func payload(_ alarm: Alarm) -> [String: Any] {
        var output: [String: Any] = [
            "identifier": alarm.id.uuidString,
            "state": stateName(alarm.state)
        ]
        if let schedule = alarm.schedule {
            switch schedule {
            case .fixed(let date):
                output["schedule_type"] = "fixed"
                output["fire_date"] = MCPBuiltInPersonalDataDateCodec.string(date) ?? ""
            case .relative(let relative):
                output["schedule_type"] = "relative"
                output["hour"] = relative.time.hour
                output["minute"] = relative.time.minute
            }
        }
        return output
    }

    func stateName(_ state: Alarm.State) -> String {
        switch state {
        case .scheduled: return "scheduled"
        case .countdown: return "countdown"
        case .paused: return "paused"
        case .alerting: return "alerting"
        @unknown default: return "unknown"
        }
    }
}

@available(iOS 26.0, *)
private struct ETOSAlarmMetadata: AlarmMetadata {
    let title: String
}
#endif
