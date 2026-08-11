// ============================================================================
// NativeCapabilityInfrastructureTests.swift
// ============================================================================

import Testing
@testable import ETOSCore

@Suite("原生 MCP 能力基础设施测试")
struct NativeCapabilityInfrastructureTests {
    @Test("四类原生服务器公开完整且无重复的工具目录")
    func nativeToolCatalogsAreComplete() {
        let personal = Set(MCPNativePersonalDataToolDefinitions.descriptions.map(\.toolId))
        let device = Set(MCPNativeDeviceToolDefinitions.descriptions.map(\.toolId))
        let media = Set(MCPNativeMediaToolDefinitions.descriptions.map(\.toolId))
        let visionLanguage = Set(MCPNativeVisionLanguageToolDefinitions.descriptions.map(\.toolId))

        #expect(personal == [
            "contacts.search", "contacts.get", "contacts.create", "contacts.update", "contacts.delete",
            "photos.search", "photos.export_asset", "photos.save_asset", "photos.create_album",
            "photos.add_to_album", "location.get_current", "location.reverse_geocode", "location.search_places"
        ])
        #expect(device == [
            "clipboard.read", "clipboard.write", "clipboard.clear",
            "notifications.list_pending", "notifications.schedule", "notifications.cancel",
            "notifications.list_delivered", "notifications.remove_delivered",
            "alarms.list", "alarms.schedule", "alarms.cancel",
            "maps.search", "maps.directions", "maps.open", "device.open_url", "device.get_status"
        ])
        #expect(media == [
            "speech.speak", "speech.stop", "speech.transcribe_file",
            "media.play_file", "media.pause", "media.resume", "media.stop", "media.status",
            "weather.current", "weather.hourly_forecast", "weather.daily_forecast",
            "home.list_homes", "home.list_accessories", "home.list_scenes",
            "home.read_characteristic", "home.write_characteristic", "home.execute_scene",
            "bluetooth.scan", "bluetooth.connect", "bluetooth.discover_services",
            "bluetooth.read_characteristic", "bluetooth.write_characteristic",
            "bluetooth.subscribe", "bluetooth.disconnect",
            "nfc.scan", "nfc.read_ndef", "nfc.write_ndef"
        ])
        #expect(visionLanguage == [
            "vision.recognize_text", "vision.detect_barcodes", "vision.classify_image",
            "vision.detect_document", "language.detect", "language.tokenize",
            "language.sentiment", "language.entities"
        ])

        let all = personal.union(device).union(media).union(visionLanguage)
        #expect(all.count == personal.count + device.count + media.count + visionLanguage.count)
    }

    @Test("外部副作用和私人数据写入始终要求逐次审批")
    func irreversibleNativeToolsRequirePerCallApproval() {
        let required = [
            "contacts.create", "contacts.update", "contacts.delete",
            "photos.export_asset", "photos.save_asset", "photos.create_album", "photos.add_to_album",
            "clipboard.write", "clipboard.clear",
            "notifications.schedule", "notifications.cancel", "notifications.remove_delivered",
            "alarms.schedule", "alarms.cancel", "maps.open", "device.open_url",
            "speech.speak", "speech.stop", "media.play_file", "media.pause", "media.resume", "media.stop",
            "home.write_characteristic", "home.execute_scene",
            "bluetooth.connect", "bluetooth.write_characteristic", "bluetooth.subscribe", "bluetooth.disconnect",
            "nfc.scan", "nfc.read_ndef", "nfc.write_ndef"
        ]

        #expect(required.allSatisfy(MCPNativeCapabilityPolicy.requiresPerCallApproval))
        #expect(!MCPNativeCapabilityPolicy.requiresPerCallApproval("contacts.search"))
        #expect(!MCPNativeCapabilityPolicy.requiresPerCallApproval("weather.current"))
        #expect(!MCPNativeCapabilityPolicy.requiresPerCallApproval("vision.recognize_text"))
    }
}
