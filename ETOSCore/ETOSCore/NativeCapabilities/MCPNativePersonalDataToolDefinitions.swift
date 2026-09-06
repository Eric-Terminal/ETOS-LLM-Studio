// ============================================================================
// MCPNativePersonalDataToolDefinitions.swift
// ============================================================================
// ETOS LLM Studio
//
// 联系人、照片与位置能力继续归入“内建个人数据”服务器。
// ============================================================================

import Foundation
import MCP

enum MCPNativePersonalDataToolDefinitions {
    static let toolIDs = [
        "contacts.search",
        "contacts.get",
        "contacts.create",
        "contacts.update",
        "contacts.delete",
        "photos.search",
        "photos.export_asset",
        "photos.save_asset",
        "photos.create_album",
        "photos.add_to_album",
        "location.get_current",
        "location.reverse_geocode",
        "location.search_places"
    ]

    static var descriptions: [MCPToolDescription] {
        [
            MCPToolDescription(
                toolId: "contacts.search",
                description: NSLocalizedString("按姓名、组织、电话号码或邮箱搜索系统联系人。正式调用时申请联系人读取权限。", comment: "Contacts search tool description"),
                inputSchema: object([
                    "query": string(NSLocalizedString("搜索文字；留空时按名称列出联系人。", comment: "Contacts search query")),
                    "limit": integer(NSLocalizedString("最大结果数，默认 25，最大 100。", comment: "Contacts search limit"), minimum: 1, maximum: 100)
                ])
            ),
            MCPToolDescription(
                toolId: "contacts.get",
                description: NSLocalizedString("按联系人 ID 读取姓名、组织、电话号码、邮箱和邮寄地址。", comment: "Contact get tool description"),
                inputSchema: object([
                    "contact_id": string(NSLocalizedString("联系人 ID。", comment: "Contact identifier"))
                ], required: ["contact_id"])
            ),
            MCPToolDescription(
                toolId: "contacts.create",
                description: NSLocalizedString("创建系统联系人。该写操作始终需要逐次确认；watchOS 会明确返回不支持。", comment: "Contact create tool description"),
                inputSchema: contactWriteSchema(required: ["given_name"])
            ),
            MCPToolDescription(
                toolId: "contacts.update",
                description: NSLocalizedString("更新已有系统联系人。仅修改请求中出现的字段，并始终需要逐次确认。", comment: "Contact update tool description"),
                inputSchema: contactWriteSchema(required: ["contact_id"])
            ),
            MCPToolDescription(
                toolId: "contacts.delete",
                description: NSLocalizedString("删除指定系统联系人。该操作不可由工具自动绕过逐次确认。", comment: "Contact delete tool description"),
                inputSchema: object([
                    "contact_id": string(NSLocalizedString("联系人 ID。", comment: "Contact identifier"))
                ], required: ["contact_id"])
            ),
            MCPToolDescription(
                toolId: "photos.search",
                description: NSLocalizedString("按日期、媒体类型和文件名搜索系统照片图库中的资源。正式调用时申请照片读取权限。", comment: "Photos search tool description"),
                inputSchema: object([
                    "query": string(NSLocalizedString("可选文件名关键字。", comment: "Photo filename query")),
                    "media_type": enumeration(NSLocalizedString("媒体类型。", comment: "Photo media type"), values: ["image", "video", "any"]),
                    "start_date": string(NSLocalizedString("可选 ISO-8601 开始时间。", comment: "Photo search start date")),
                    "end_date": string(NSLocalizedString("可选 ISO-8601 结束时间。", comment: "Photo search end date")),
                    "limit": integer(NSLocalizedString("最大结果数，默认 50，最大 200。", comment: "Photo search limit"), minimum: 1, maximum: 200)
                ])
            ),
            MCPToolDescription(
                toolId: "photos.export_asset",
                description: NSLocalizedString("把指定照片或视频导出到 Documents 中的 app:// URI。覆盖已有文件必须显式声明，且始终逐次确认。", comment: "Photo export tool description"),
                inputSchema: object([
                    "asset_id": string(NSLocalizedString("照片资源 ID。", comment: "Photo asset identifier")),
                    "destination": string(NSLocalizedString("目标 app:// URI；省略时写入 NativeExports/Photos。", comment: "Photo export destination")),
                    "overwrite": boolean(NSLocalizedString("是否允许覆盖已有文件，默认 false。", comment: "Photo export overwrite"))
                ], required: ["asset_id"])
            ),
            MCPToolDescription(
                toolId: "photos.save_asset",
                description: NSLocalizedString("把 Documents 中的 app:// 图片或视频保存到系统照片图库。始终需要逐次确认。", comment: "Photo save asset tool description"),
                inputSchema: object([
                    "source": string(NSLocalizedString("源文件 app:// URI。", comment: "Photo save source"))
                ], required: ["source"])
            ),
            MCPToolDescription(
                toolId: "photos.create_album",
                description: NSLocalizedString("创建系统照片相簿。始终需要逐次确认。", comment: "Photo create album tool description"),
                inputSchema: object([
                    "title": string(NSLocalizedString("相簿名称。", comment: "Photo album title"))
                ], required: ["title"])
            ),
            MCPToolDescription(
                toolId: "photos.add_to_album",
                description: NSLocalizedString("把一个或多个照片资源加入指定相簿。始终需要逐次确认。", comment: "Photo add to album tool description"),
                inputSchema: object([
                    "album_id": string(NSLocalizedString("相簿 ID。", comment: "Photo album identifier")),
                    "asset_ids": array(of: string(NSLocalizedString("照片资源 ID。", comment: "Photo asset identifier")), description: NSLocalizedString("要加入相簿的照片资源 ID。", comment: "Photo asset identifiers"))
                ], required: ["album_id", "asset_ids"])
            ),
            MCPToolDescription(
                toolId: "location.get_current",
                description: NSLocalizedString("读取一次当前设备位置；不启动持续跟踪。正式调用时请求使用期间位置权限。", comment: "Current location tool description"),
                inputSchema: object([
                    "accuracy": enumeration(NSLocalizedString("期望精度。", comment: "Current location accuracy"), values: ["best", "hundred_meters", "kilometer"])
                ])
            ),
            MCPToolDescription(
                toolId: "location.reverse_geocode",
                description: NSLocalizedString("把经纬度反向解析为地址，不读取设备当前位置。", comment: "Reverse geocode tool description"),
                inputSchema: coordinateSchema()
            ),
            MCPToolDescription(
                toolId: "location.search_places",
                description: NSLocalizedString("使用 MapKit 搜索地点；可提供中心点与半径约束结果。", comment: "Place search tool description"),
                inputSchema: object([
                    "query": string(NSLocalizedString("地点、地址或类别搜索文字。", comment: "Place search query")),
                    "latitude": number(NSLocalizedString("可选中心纬度。", comment: "Place search latitude")),
                    "longitude": number(NSLocalizedString("可选中心经度。", comment: "Place search longitude")),
                    "radius_meters": number(NSLocalizedString("搜索半径，默认 5000 米。", comment: "Place search radius")),
                    "limit": integer(NSLocalizedString("最大结果数，默认 10，最大 25。", comment: "Place search limit"), minimum: 1, maximum: 25)
                ], required: ["query"])
            )
        ]
    }

    private static func contactWriteSchema(required: [String]) -> JSONValue {
        object([
            "contact_id": string(NSLocalizedString("更新时使用的联系人 ID。", comment: "Contact update identifier")),
            "given_name": string(NSLocalizedString("名。", comment: "Contact given name")),
            "family_name": string(NSLocalizedString("姓。", comment: "Contact family name")),
            "organization": string(NSLocalizedString("组织名称。", comment: "Contact organization")),
            "phone_numbers": array(of: string(NSLocalizedString("电话号码。", comment: "Contact phone number")), description: NSLocalizedString("电话号码列表；更新时会替换原列表。", comment: "Contact phone numbers")),
            "email_addresses": array(of: string(NSLocalizedString("邮箱地址。", comment: "Contact email address")), description: NSLocalizedString("邮箱列表；更新时会替换原列表。", comment: "Contact email addresses")),
            "street": string(NSLocalizedString("街道地址。", comment: "Contact street")),
            "city": string(NSLocalizedString("城市。", comment: "Contact city")),
            "state": string(NSLocalizedString("省、州或地区。", comment: "Contact state")),
            "postal_code": string(NSLocalizedString("邮政编码。", comment: "Contact postal code")),
            "country": string(NSLocalizedString("国家或地区。", comment: "Contact country"))
        ], required: required)
    }

    private static func coordinateSchema() -> JSONValue {
        object([
            "latitude": number(NSLocalizedString("纬度。", comment: "Coordinate latitude")),
            "longitude": number(NSLocalizedString("经度。", comment: "Coordinate longitude"))
        ], required: ["latitude", "longitude"])
    }

    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        MCPBuiltInPersonalDataServer.objectSchema(properties: properties, required: required)
    }

    private static func string(_ description: String) -> JSONValue {
        MCPBuiltInPersonalDataServer.stringSchema(description)
    }

    private static func number(_ description: String) -> JSONValue {
        MCPBuiltInPersonalDataServer.numberSchema(description)
    }

    private static func integer(_ description: String, minimum: Int, maximum: Int) -> JSONValue {
        MCPBuiltInPersonalDataServer.integerSchema(description, minimum: minimum, maximum: maximum)
    }

    private static func boolean(_ description: String) -> JSONValue {
        MCPBuiltInPersonalDataServer.boolSchema(description)
    }

    private static func enumeration(_ description: String, values: [String]) -> JSONValue {
        MCPBuiltInPersonalDataServer.enumSchema(description, values: values)
    }

    private static func array(of item: JSONValue, description: String) -> JSONValue {
        .dictionary([
            "type": .string("array"),
            "description": .string(description),
            "items": item
        ])
    }
}
