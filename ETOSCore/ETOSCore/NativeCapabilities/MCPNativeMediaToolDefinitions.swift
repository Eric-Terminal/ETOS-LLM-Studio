// ============================================================================
// MCPNativeMediaToolDefinitions.swift
// ============================================================================
// ETOS LLM Studio
//
// 媒体与环境服务器的 MCP schema。
// ============================================================================

import Foundation
import MCP

enum MCPNativeMediaToolDefinitions {
    private static let toolIDs: Set<String> = [
        "speech.speak", "speech.stop", "speech.transcribe_file",
        "media.play_file", "media.pause", "media.resume", "media.stop", "media.status",
        "weather.current", "weather.hourly_forecast", "weather.daily_forecast",
        "home.list_homes", "home.list_accessories", "home.list_scenes",
        "home.read_characteristic", "home.write_characteristic", "home.execute_scene",
        "bluetooth.scan", "bluetooth.connect", "bluetooth.discover_services",
        "bluetooth.read_characteristic", "bluetooth.write_characteristic",
        "bluetooth.subscribe", "bluetooth.disconnect",
        "nfc.scan", "nfc.read_ndef", "nfc.write_ndef"
    ]

    static func contains(_ toolID: String) -> Bool {
        toolIDs.contains(toolID)
    }

    static var descriptions: [MCPToolDescription] {
        definitions.map { definition in
            MCPToolDescription(
                toolId: definition.id,
                description: NSLocalizedString(definition.summary, comment: "Native media MCP tool description"),
                inputSchema: definition.schema
            )
        }
    }

    private static var definitions: [Definition] {
        [
            tool("speech.speak", "使用系统语音在当前设备朗读文本；只控制 ETOS 发起的朗读，并始终逐次确认。", object([
                "text": string("要朗读的文本。"),
                "language": string("可选 BCP-47 语言代码。"),
                "rate": number("相对语速 0 到 1，默认 0.5。"),
                "pitch": number("音高 0.5 到 2，默认 1。"),
                "volume": number("音量 0 到 1，默认 1。")
            ], required: ["text"])),
            tool("speech.stop", "停止 ETOS 当前发起的系统语音朗读，并始终逐次确认。", object()),
            tool("speech.transcribe_file", "转写 Documents 中 app:// 音频文件。正式调用时申请语音识别权限；watchOS 委托给 iPhone。", object([
                "source": string("音频文件 app:// URI。"),
                "locale": string("可选 BCP-47 识别语言代码。"),
                "punctuation": boolean("是否自动添加标点，默认 true。")
            ], required: ["source"])),
            tool("media.play_file", "播放 Documents 中 app:// 音频或视频文件的声音轨；只控制 ETOS 自己创建的播放器，并始终逐次确认。", object([
                "source": string("媒体文件 app:// URI。"),
                "volume": number("播放音量 0 到 1，默认 1。"),
                "loop": boolean("是否循环播放，默认 false。")
            ], required: ["source"])),
            tool("media.pause", "暂停 ETOS 当前播放器，并始终逐次确认。", object()),
            tool("media.resume", "恢复 ETOS 当前播放器，并始终逐次确认。", object()),
            tool("media.stop", "停止并释放 ETOS 当前播放器，并始终逐次确认。", object()),
            tool("media.status", "读取 ETOS 当前播放器状态；不会检查或控制其他应用的媒体。", object()),
            tool("weather.current", "使用 WeatherKit 查询指定坐标的当前天气；不会读取设备当前位置。", coordinateSchema()),
            tool("weather.hourly_forecast", "使用 WeatherKit 查询指定坐标的逐小时预报。", object([
                "latitude": number("纬度。"), "longitude": number("经度。"),
                "hours": integer("小时数，默认 24，最大 48。", 1, 48)
            ], required: ["latitude", "longitude"])),
            tool("weather.daily_forecast", "使用 WeatherKit 查询指定坐标的逐日预报。", object([
                "latitude": number("纬度。"), "longitude": number("经度。"),
                "days": integer("天数，默认 7，最大 10。", 1, 10)
            ], required: ["latitude", "longitude"])),
            tool("home.list_homes", "列出当前用户授权给 ETOS 的家庭。HomeKit 会在首次正式调用时管理系统授权。", object()),
            tool("home.list_accessories", "列出指定家庭中的配件、服务与特征。", object([
                "home_id": string("家庭 UUID。")
            ], required: ["home_id"])),
            tool("home.list_scenes", "列出指定家庭中的 HomeKit 场景。", object([
                "home_id": string("家庭 UUID。")
            ], required: ["home_id"])),
            tool("home.read_characteristic", "读取指定 HomeKit 特征的当前值。", characteristicSchema(includeValue: false)),
            tool("home.write_characteristic", "写入指定 HomeKit 特征。系统会按特征元数据校验值，且该操作始终逐次确认。", characteristicSchema(includeValue: true)),
            tool("home.execute_scene", "执行指定 HomeKit 场景，并始终逐次确认。", object([
                "home_id": string("家庭 UUID。"), "scene_id": string("场景 UUID。")
            ], required: ["home_id", "scene_id"])),
            tool("bluetooth.scan", "在有限时长内扫描附近 BLE 外设，结束后立即停止扫描。", object([
                "duration_seconds": number("扫描秒数，默认 5，最大 15。"),
                "service_uuids": stringArray("可选 BLE 服务 UUID 过滤列表。")
            ])),
            tool("bluetooth.connect", "连接扫描得到的 BLE 外设。连接绑定当前会话或 Agent Run，并始终逐次确认。", object([
                "peripheral_id": string("外设 UUID。")
            ], required: ["peripheral_id"])),
            tool("bluetooth.discover_services", "发现已连接 BLE 外设的服务和特征。", object([
                "peripheral_id": string("外设 UUID。")
            ], required: ["peripheral_id"])),
            tool("bluetooth.read_characteristic", "读取已连接 BLE 外设的特征值。", bluetoothCharacteristicSchema(includeValue: false)),
            tool("bluetooth.write_characteristic", "写入已连接 BLE 外设的特征值，并始终逐次确认。", bluetoothCharacteristicSchema(includeValue: true)),
            tool("bluetooth.subscribe", "开启或关闭 BLE 特征通知；订阅会在 Run 结束或连接释放时清理，并始终逐次确认。", object([
                "peripheral_id": string("外设 UUID。"),
                "service_uuid": string("服务 UUID。"),
                "characteristic_uuid": string("特征 UUID。"),
                "enabled": boolean("是否启用通知。")
            ], required: ["peripheral_id", "service_uuid", "characteristic_uuid", "enabled"])),
            tool("bluetooth.disconnect", "断开当前会话或 Run 中的 BLE 外设并清理订阅。", object([
                "peripheral_id": string("外设 UUID。")
            ], required: ["peripheral_id"])),
            tool("nfc.scan", "显示系统 NFC 扫描界面并读取一次标签类型与标识。仅 iPhone 支持；watchOS 委托给 iPhone，并始终逐次确认。", object()),
            tool("nfc.read_ndef", "显示系统 NFC 界面并读取一次 NDEF 消息。仅 iPhone 支持；watchOS 委托给 iPhone，并始终逐次确认。", object()),
            tool("nfc.write_ndef", "预览并写入一次 NDEF 记录。必须显式 confirmed=true，仍会经过逐次审批和系统 NFC 界面。", object([
                "records": ndefRecordsSchema(),
                "confirmed": boolean("确认写入预览中的全部记录。")
            ], required: ["records", "confirmed"]))
        ]
    }

    private struct Definition { let id: String; let summary: String; let schema: JSONValue }
    private static func tool(_ id: String, _ summary: String, _ schema: JSONValue) -> Definition {
        Definition(id: id, summary: summary, schema: schema)
    }

    private static func coordinateSchema() -> JSONValue {
        object(["latitude": number("纬度。"), "longitude": number("经度。")], required: ["latitude", "longitude"])
    }

    private static func characteristicSchema(includeValue: Bool) -> JSONValue {
        var properties = [
            "home_id": string("家庭 UUID。"), "accessory_id": string("配件 UUID。"),
            "service_id": string("服务 UUID。"), "characteristic_id": string("特征 UUID。")
        ]
        var required = ["home_id", "accessory_id", "service_id", "characteristic_id"]
        if includeValue {
            properties["value"] = scalar("要写入的布尔值、数字或字符串。")
            required.append("value")
        }
        return object(properties, required: required)
    }

    private static func bluetoothCharacteristicSchema(includeValue: Bool) -> JSONValue {
        var properties = [
            "peripheral_id": string("外设 UUID。"), "service_uuid": string("服务 UUID。"),
            "characteristic_uuid": string("特征 UUID。")
        ]
        var required = ["peripheral_id", "service_uuid", "characteristic_uuid"]
        if includeValue {
            properties["value_base64"] = string("要写入的二进制值，使用 Base64。")
            required.append("value_base64")
        }
        return object(properties, required: required)
    }

    private static func ndefRecordsSchema() -> JSONValue {
        .dictionary([
            "type": .string("array"), "minItems": .int(1),
            "description": .string(NSLocalizedString("要写入的 NDEF 记录预览。", comment: "NDEF records parameter")),
            "items": object([
                "kind": enumeration("记录类型。", ["text", "uri", "mime", "external"]),
                "value": string("文本、URL 或 Base64 数据。"),
                "language": string("文本记录语言代码，默认 en。"),
                "mime_type": string("MIME 记录类型。"),
                "external_type": string("外部记录类型，例如 example.com:type。")
            ], required: ["kind", "value"])
        ])
    }

    private static func object(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        var result: [String: JSONValue] = ["type": .string("object"), "properties": .dictionary(properties), "additionalProperties": .bool(false)]
        if !required.isEmpty { result["required"] = .array(required.map { .string($0) }) }
        return .dictionary(result)
    }

    private static func string(_ description: String) -> JSONValue { typed("string", description) }
    private static func number(_ description: String) -> JSONValue { typed("number", description) }
    private static func boolean(_ description: String) -> JSONValue { typed("boolean", description) }
    private static func scalar(_ description: String) -> JSONValue {
        .dictionary([
            "description": .string(NSLocalizedString(description, comment: "Native media MCP scalar parameter")),
            "oneOf": .array(["boolean", "number", "string"].map { .dictionary(["type": .string($0)]) })
        ])
    }
    private static func integer(_ description: String, _ min: Int, _ max: Int) -> JSONValue {
        .dictionary(["type": .string("integer"), "description": .string(NSLocalizedString(description, comment: "Native media MCP integer parameter")), "minimum": .int(min), "maximum": .int(max)])
    }
    private static func enumeration(_ description: String, _ values: [String]) -> JSONValue {
        .dictionary(["type": .string("string"), "description": .string(NSLocalizedString(description, comment: "Native media MCP enum parameter")), "enum": .array(values.map { .string($0) })])
    }
    private static func stringArray(_ description: String) -> JSONValue {
        .dictionary(["type": .string("array"), "description": .string(NSLocalizedString(description, comment: "Native media MCP array parameter")), "items": .dictionary(["type": .string("string")])])
    }
    private static func typed(_ type: String, _ description: String) -> JSONValue {
        .dictionary(["type": .string(type), "description": .string(NSLocalizedString(description, comment: "Native media MCP parameter"))])
    }
}
