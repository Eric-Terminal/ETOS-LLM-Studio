// ============================================================================
// MCPNativeDeviceStatusExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// 返回即时、非跟踪设备状态，不注册监听或后台采样。
// ============================================================================

import Foundation
#if os(iOS) && canImport(UIKit)
import UIKit
#endif
#if os(watchOS) && canImport(WatchKit)
import WatchKit
#endif

actor MCPNativeDeviceStatusExecutor {
    func execute() async throws -> [String: Any] {
        let process = ProcessInfo.processInfo
        #if os(watchOS)
        let capacity = try? StorageUtility.documentsDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey
        ])
        let availableStorage: Any = capacity?.volumeAvailableCapacity ?? NSNull()
        #else
        let capacity = try? StorageUtility.documentsDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ])
        let availableStorage: Any = capacity?.volumeAvailableCapacityForImportantUsage ?? NSNull()
        #endif
        let device = await devicePayload()
        return [
            "platform": platformName,
            "device": device,
            "operating_system": process.operatingSystemVersionString,
            "low_power_mode": process.isLowPowerModeEnabled,
            "thermal_state": thermalStateName(process.thermalState),
            "system_uptime_seconds": process.systemUptime,
            "available_storage_bytes": availableStorage,
            "total_storage_bytes": capacity?.volumeTotalCapacity ?? NSNull(),
            "locale": Locale.current.identifier,
            "time_zone": TimeZone.current.identifier,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build_number": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "tracking": false
        ]
    }

    private var platformName: String {
        #if os(watchOS)
        return "watchOS"
        #elseif os(iOS)
        return "iOS"
        #else
        return "unknown"
        #endif
    }

    @MainActor
    private func devicePayload() -> [String: Any] {
        #if os(iOS) && canImport(UIKit)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let battery: Any = device.batteryLevel >= 0 ? NSNumber(value: device.batteryLevel) : NSNull()
        return [
            "name": device.name,
            "model": device.model,
            "localized_model": device.localizedModel,
            "system_name": device.systemName,
            "system_version": device.systemVersion,
            "battery_level": battery
        ]
        #elseif os(watchOS) && canImport(WatchKit)
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let battery: Any = device.batteryLevel >= 0 ? NSNumber(value: device.batteryLevel) : NSNull()
        return [
            "name": device.name,
            "model": device.model,
            "localized_model": device.localizedModel,
            "system_name": device.systemName,
            "system_version": device.systemVersion,
            "battery_level": battery
        ]
        #else
        return [:]
        #endif
    }

    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
