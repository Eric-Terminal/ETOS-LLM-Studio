// ============================================================================
// MCPNativeDeviceToolDefinitions.swift
// ============================================================================
// ETOS LLM Studio
//
// 设备操作服务器的 MCP schema。服务器默认不加入聊天，危险操作逐次审批。
// ============================================================================

import Foundation
import MCP

enum MCPNativeDeviceToolDefinitions {
    private static let toolIDs: Set<String> = [
        "clipboard.read", "clipboard.write", "clipboard.clear",
        "notifications.list_pending", "notifications.schedule", "notifications.cancel",
        "notifications.list_delivered", "notifications.remove_delivered",
        "alarms.list", "alarms.schedule", "alarms.cancel",
        "maps.search", "maps.directions", "maps.open",
        "device.open_url", "device.get_status"
    ]

    static func contains(_ toolID: String) -> Bool {
        toolIDs.contains(toolID)
    }

    static var descriptions: [MCPToolDescription] {
        [
            tool("clipboard.read", "读取当前剪贴板中的纯文本。watchOS 会在可达时委托给配对 iPhone。", object()),
            tool("clipboard.write", "把纯文本写入剪贴板。该操作始终逐次确认；watchOS 会委托给配对 iPhone。", object([
                "text": string("要写入剪贴板的文本。")
            ], required: ["text"])),
            tool("clipboard.clear", "清空剪贴板。该操作始终逐次确认；watchOS 会委托给配对 iPhone。", object()),
            tool("notifications.list_pending", "列出由当前应用登记、尚未触发的本地通知。", object()),
            tool("notifications.schedule", "登记当前应用的本地通知。正式调用时请求通知权限，且始终逐次确认。", object([
                "identifier": string("通知 ID；省略时自动生成。"),
                "title": string("通知标题。"),
                "body": string("通知正文。"),
                "fire_date": string("可选 ISO-8601 触发时间。"),
                "time_interval_seconds": number("可选延迟秒数；与 fire_date 二选一。"),
                "repeats": boolean("是否重复；重复通知的时间间隔不得少于 60 秒。"),
                "sound": boolean("是否播放系统默认通知声音，默认 true。")
            ], required: ["title", "body"])),
            tool("notifications.cancel", "取消一个或多个尚未触发的本地通知。该操作始终逐次确认。", object([
                "identifiers": stringArray("要取消的通知 ID。")
            ], required: ["identifiers"])),
            tool("notifications.list_delivered", "列出通知中心中由当前应用送达的通知。", object()),
            tool("notifications.remove_delivered", "从通知中心移除一个或多个当前应用的已送达通知。该操作始终逐次确认。", object([
                "identifiers": stringArray("要移除的通知 ID。")
            ], required: ["identifiers"])),
            tool("alarms.list", "列出当前应用通过 AlarmKit 建立的闹钟。仅 iOS 26 及更高版本可用；watchOS 委托给 iPhone，不会降级为通知。", object()),
            tool("alarms.schedule", "使用 AlarmKit 建立固定时间闹钟。仅 iOS 26 及更高版本可用，绝不降级为通知，并始终逐次确认。", object([
                "title": string("闹钟标题。"),
                "fire_date": string("ISO-8601 响铃时间。"),
                "identifier": string("可选 UUID；省略时自动生成。")
            ], required: ["title", "fire_date"])),
            tool("alarms.cancel", "取消当前应用建立的 AlarmKit 闹钟。不会改用通知，并始终逐次确认。", object([
                "identifier": string("闹钟 UUID。")
            ], required: ["identifier"])),
            tool("maps.search", "使用 MapKit 搜索地点，可选中心点与半径。", placeSearchSchema()),
            tool("maps.directions", "使用 MapKit 计算两点间路线，返回距离、预计耗时和分步指引。", object([
                "source_latitude": number("起点纬度。"),
                "source_longitude": number("起点经度。"),
                "destination_latitude": number("终点纬度。"),
                "destination_longitude": number("终点经度。"),
                "transport_type": enumeration("交通方式。", ["automobile", "walking", "transit", "cycling"]),
                "alternates": boolean("是否返回备选路线。")
            ], required: ["source_latitude", "source_longitude", "destination_latitude", "destination_longitude"])),
            tool("maps.open", "在系统地图中打开地点或路线。该操作会切换应用并始终逐次确认。", object([
                "latitude": number("目标纬度。"),
                "longitude": number("目标经度。"),
                "name": string("地点名称。"),
                "directions_mode": enumeration("可选路线模式。", ["driving", "walking", "transit", "cycling"])
            ], required: ["latitude", "longitude"])),
            tool("device.open_url", "使用系统打开受支持的 URL。仅允许 http、https、mailto、tel、sms、facetime、facetime-audio 与 maps，并始终逐次确认。", object([
                "url": string("要打开的完整 URL。")
            ], required: ["url"])),
            tool("device.get_status", "读取当前设备的系统版本、低电量模式、热状态、电池与可用存储等非跟踪状态。", object())
        ].map { description in
            MCPToolDescription(
                toolId: description.id,
                description: NSLocalizedString(description.summary, comment: "Native device MCP tool description"),
                inputSchema: description.schema
            )
        }
    }

    private struct Description {
        let id: String
        let summary: String
        let schema: JSONValue
    }

    private static func tool(_ id: String, _ summary: String, _ schema: JSONValue) -> Description {
        Description(id: id, summary: summary, schema: schema)
    }

    private static func placeSearchSchema() -> JSONValue {
        object([
            "query": string("地点、地址或类别搜索文字。"),
            "latitude": number("可选中心纬度。"),
            "longitude": number("可选中心经度。"),
            "radius_meters": number("搜索半径，默认 5000 米。"),
            "limit": integer("最大结果数，默认 10，最大 25。", 1, 25)
        ], required: ["query"])
    }

    private static func object(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .dictionary(properties),
            "additionalProperties": .bool(false)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .dictionary(schema)
    }

    private static func string(_ description: String) -> JSONValue {
        .dictionary(["type": .string("string"), "description": .string(NSLocalizedString(description, comment: "Native device MCP string parameter"))])
    }

    private static func number(_ description: String) -> JSONValue {
        .dictionary(["type": .string("number"), "description": .string(NSLocalizedString(description, comment: "Native device MCP number parameter"))])
    }

    private static func integer(_ description: String, _ minimum: Int, _ maximum: Int) -> JSONValue {
        .dictionary([
            "type": .string("integer"),
            "description": .string(NSLocalizedString(description, comment: "Native device MCP integer parameter")),
            "minimum": .int(minimum),
            "maximum": .int(maximum)
        ])
    }

    private static func boolean(_ description: String) -> JSONValue {
        .dictionary(["type": .string("boolean"), "description": .string(NSLocalizedString(description, comment: "Native device MCP boolean parameter"))])
    }

    private static func enumeration(_ description: String, _ values: [String]) -> JSONValue {
        .dictionary([
            "type": .string("string"),
            "description": .string(NSLocalizedString(description, comment: "Native device MCP enum parameter")),
            "enum": .array(values.map { .string($0) })
        ])
    }

    private static func stringArray(_ description: String) -> JSONValue {
        .dictionary([
            "type": .string("array"),
            "description": .string(NSLocalizedString(description, comment: "Native device MCP array parameter")),
            "items": .dictionary(["type": .string("string")]),
            "minItems": .int(1)
        ])
    }
}
