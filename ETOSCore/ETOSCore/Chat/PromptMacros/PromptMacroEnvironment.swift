// ============================================================================
// PromptMacroEnvironment.swift
// ============================================================================
// 为一次请求采集设备快照；电池监测只在模板引用电池宏时短暂开启。
// ============================================================================

import Foundation
import Darwin
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

enum PromptMacroEnvironment {
    static func capture(referencedNames: Set<String>) async -> [String: String] {
        let process = ProcessInfo.processInfo
        let version = process.operatingSystemVersion
        #if os(iOS)
        let platform = "iOS"
        #elseif os(watchOS)
        let platform = "watchOS"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "unknown"
        #endif
        var values = [
            "platform": platform,
            "system_version": "\(platform) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "low_power_mode": process.isLowPowerModeEnabled ? "true" : "false",
            "system_uptime": String(Int64(process.systemUptime)),
            "app_name": Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ETOS LLM Studio",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        ]
        switch process.thermalState {
        case .nominal: values["thermal_state"] = "nominal"
        case .fair: values["thermal_state"] = "fair"
        case .serious: values["thermal_state"] = "serious"
        case .critical: values["thermal_state"] = "critical"
        @unknown default: values["thermal_state"] = "unknown"
        }

        let needsBattery = !referencedNames.isDisjoint(with: PromptMacroResolver.batteryNames)
        if needsBattery || !referencedNames.isDisjoint(with: ["device_info", "device_model", "device_name"]) {
            let hardware = hardwareIdentifier()
            values.merge(await deviceValues(hardware: hardware, includesBattery: needsBattery)) { _, new in new }
        }
        if !referencedNames.isDisjoint(with: PromptMacroResolver.audioNames) {
            values.merge(PromptMacroAudioEnvironment.capture()) { _, new in new }
        }
        if !referencedNames.isDisjoint(with: PromptMacroResolver.screenNames) {
            values.merge(await PromptMacroScreenEnvironment.capture()) { _, new in new }
        }
        if !referencedNames.isDisjoint(with: PromptMacroResolver.storageNames) {
            values.merge(PromptMacroResourceEnvironment.captureStorage()) { _, new in new }
        }
        if !referencedNames.isDisjoint(with: PromptMacroResolver.hardwareNames) {
            values.merge([
                "physical_memory_bytes": String(process.physicalMemory),
                "physical_memory_gb": PromptMacroResourceEnvironment.gigabytes(Double(process.physicalMemory)),
                "processor_count": String(process.processorCount),
                "active_processor_count": String(process.activeProcessorCount)
            ]) { _, new in new }
        }
        return values
    }

    static func batteryValues(level: Float, state: String) -> [String: String] {
        // 模拟器和暂不可用的传感器会返回 -1，不能把它当成 0% 或假定正在放电。
        return [
            "battery_level": percentageValue(level),
            "battery_state": state,
            "is_charging": state == "unknown" ? "unknown" : (state == "charging" ? "true" : "false")
        ]
    }

    static func percentageValue(_ value: Float) -> String {
        value.isFinite && (0...1).contains(value)
            ? String(Int((value * 100).rounded())) : "unknown"
    }

    @MainActor
    private static func deviceValues(hardware: String, includesBattery: Bool) -> [String: String] {
        #if os(iOS) || os(watchOS)
        #if os(iOS)
        let device = UIDevice.current
        #else
        let device = WKInterfaceDevice.current()
        #endif
        var values = [
            "device_model": hardware,
            "device_info": "\(device.model) (\(hardware))",
            "device_name": device.name
        ]
        if includesBattery {
            let wasMonitoring = device.isBatteryMonitoringEnabled
            device.isBatteryMonitoringEnabled = true
            defer { device.isBatteryMonitoringEnabled = wasMonitoring }
            let state: String
            switch device.batteryState {
            case .unknown: state = "unknown"
            case .unplugged: state = "unplugged"
            case .charging: state = "charging"
            case .full: state = "full"
            @unknown default: state = "unknown"
            }
            values.merge(batteryValues(level: device.batteryLevel, state: state)) { _, new in new }
        }
        return values
        #else
        return [
            "device_model": hardware, "device_info": hardware, "device_name": "unknown",
            "battery_level": "unknown", "battery_state": "unknown", "is_charging": "unknown"
        ]
        #endif
    }

    private static func hardwareIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let simulatedModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulatedModel
        }
        #endif
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
