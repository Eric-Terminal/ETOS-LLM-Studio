// ============================================================================
// MCPNativeCapabilityAvailability.swift
// ============================================================================
// 原生工具只公布本机可以执行的能力；缓存目录和实际调用共用同一边界。
// ============================================================================

import Foundation
#if os(iOS) && canImport(CoreNFC)
import CoreNFC
#endif

enum MCPNativeCapabilityAvailability {
    static func isToolAvailableOnCurrentPlatform(_ toolID: String) -> Bool {
        if MCPNativeVisionLanguageToolDefinitions.contains(toolID) {
            return MCPNativeVisionLanguageToolDefinitions.isToolAvailableOnCurrentPlatform(toolID)
        }
        guard MCPNativeDeviceToolDefinitions.contains(toolID)
                || MCPNativeMediaToolDefinitions.contains(toolID) else { return false }

        switch toolID {
        case _ where toolID.hasPrefix("clipboard."):
            #if os(iOS) && canImport(UIKit)
            return true
            #else
            return false
            #endif
        case _ where toolID.hasPrefix("alarms."):
            #if os(iOS) && canImport(AlarmKit)
            if #available(iOS 26.0, *) { return true }
            #endif
            return false
        case _ where toolID.hasPrefix("notifications."):
            #if canImport(UserNotifications)
            return true
            #else
            return false
            #endif
        case _ where toolID.hasPrefix("maps."):
            #if canImport(MapKit)
            return true
            #else
            return false
            #endif
        case "device.open_url", "device.get_status":
            return true
        case "speech.transcribe_file":
            #if os(iOS) && canImport(Speech)
            return true
            #else
            return false
            #endif
        case _ where toolID.hasPrefix("speech."), _ where toolID.hasPrefix("media."):
            #if canImport(AVFoundation)
            return true
            #else
            return false
            #endif
        case _ where toolID.hasPrefix("weather."):
            #if canImport(WeatherKit) && canImport(CoreLocation)
            return true
            #else
            return false
            #endif
        case _ where toolID.hasPrefix("home."):
            #if canImport(HomeKit)
            return true
            #else
            return false
            #endif
        case _ where toolID.hasPrefix("bluetooth."):
            #if canImport(CoreBluetooth)
            return true
            #else
            return false
            #endif
        case _ where toolID.hasPrefix("nfc."):
            #if os(iOS) && canImport(CoreNFC)
            return NFCReaderSession.readingAvailable
            #else
            return false
            #endif
        default:
            return false
        }
    }
}
