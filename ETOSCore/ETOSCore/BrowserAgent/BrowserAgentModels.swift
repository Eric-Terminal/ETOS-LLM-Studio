// ============================================================================
// BrowserAgentModels.swift
// ============================================================================
// ETOS LLM Studio
//
// Browser Agent 的公开协议。浏览器实例按聊天会话隔离，模型只能使用路由层
// 注入的可信 sessionID，不能通过工具参数跨会话访问标签页。
// ============================================================================

import Foundation

public enum BrowserAgentAction: String, Codable, CaseIterable, Sendable {
    case capabilities
    case listTabs = "list_tabs"
    case openTab = "open_tab"
    case navigate
    case snapshot
    case click
    case type
    case scroll
    case evaluateJavaScript = "evaluate_javascript"
    case screenshot
    case download
    case closeTab = "close_tab"
}

public enum BrowserAgentDataProfile: String, Codable, CaseIterable, Sendable {
    /// 每个新标签页使用临时网站数据，退出进程后不会保留登录态。
    case sessionIsolated = "session_isolated"
    /// 使用系统默认网站数据仓，允许不同会话复用用户明确选择保留的登录态。
    case persistentShared = "persistent_shared"

    public var displayName: String {
        switch self {
        case .sessionIsolated:
            return NSLocalizedString("会话隔离", comment: "Browser Agent isolated data profile")
        case .persistentShared:
            return NSLocalizedString("持久共享登录态", comment: "Browser Agent persistent data profile")
        }
    }
}

public struct BrowserAgentCapabilities: Codable, Equatable, Sendable {
    public let platform: String
    public let isExperimental: Bool
    public let supportsNavigation: Bool
    public let supportsSnapshot: Bool
    public let supportsClick: Bool
    public let supportsTyping: Bool
    public let supportsScrolling: Bool
    public let supportsJavaScript: Bool
    public let supportsScreenshot: Bool
    public let supportsDownload: Bool
    public let supportsUserTakeover: Bool
    public let supportsIPhoneDelegation: Bool
    public let notes: [String]

    public init(
        platform: String,
        isExperimental: Bool,
        supportsNavigation: Bool,
        supportsSnapshot: Bool,
        supportsClick: Bool,
        supportsTyping: Bool,
        supportsScrolling: Bool,
        supportsJavaScript: Bool,
        supportsScreenshot: Bool,
        supportsDownload: Bool,
        supportsUserTakeover: Bool,
        supportsIPhoneDelegation: Bool,
        notes: [String]
    ) {
        self.platform = platform
        self.isExperimental = isExperimental
        self.supportsNavigation = supportsNavigation
        self.supportsSnapshot = supportsSnapshot
        self.supportsClick = supportsClick
        self.supportsTyping = supportsTyping
        self.supportsScrolling = supportsScrolling
        self.supportsJavaScript = supportsJavaScript
        self.supportsScreenshot = supportsScreenshot
        self.supportsDownload = supportsDownload
        self.supportsUserTakeover = supportsUserTakeover
        self.supportsIPhoneDelegation = supportsIPhoneDelegation
        self.notes = notes
    }
}

public enum BrowserAgentCapability: String, CaseIterable, Hashable, Sendable {
    case navigation
    case snapshot
    case click
    case typing
    case scrolling
    case javaScript
    case screenshot
    case download
    case userTakeover
}

public extension BrowserAgentCapabilities {
    /// 只返回影响本机浏览与模型操作的缺口；iPhone 委托属于可选传输方式，不算缺口。
    var unavailableCapabilities: [BrowserAgentCapability] {
        [
            (supportsNavigation, .navigation),
            (supportsSnapshot, .snapshot),
            (supportsClick, .click),
            (supportsTyping, .typing),
            (supportsScrolling, .scrolling),
            (supportsJavaScript, .javaScript),
            (supportsScreenshot, .screenshot),
            (supportsDownload, .download),
            (supportsUserTakeover, .userTakeover)
        ].compactMap { isAvailable, capability in
            isAvailable ? nil : capability
        }
    }
}

public struct BrowserAgentTabSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let url: String?
    public let isLoading: Bool

    public init(id: UUID, title: String, url: String?, isLoading: Bool) {
        self.id = id
        self.title = title
        self.url = url
        self.isLoading = isLoading
    }
}

public struct BrowserAgentSnapshot: Codable, Equatable, Sendable {
    public struct Element: Codable, Equatable, Sendable {
        public let index: Int
        public let role: String
        public let label: String
        public let value: String?

        public init(index: Int, role: String, label: String, value: String?) {
            self.index = index
            self.role = role
            self.label = label
            self.value = value
        }
    }

    public let title: String
    public let url: String?
    public let text: String
    public let elements: [Element]
    public let wasTruncated: Bool

    public init(title: String, url: String?, text: String, elements: [Element], wasTruncated: Bool) {
        self.title = title
        self.url = url
        self.text = text
        self.elements = elements
        self.wasTruncated = wasTruncated
    }
}

public enum BrowserAgentError: LocalizedError, Sendable {
    case invalidArguments(String)
    case tabNotFound
    case unsupported(String)
    case navigationFailed(String)
    case javaScriptFailed(String)
    case crossDomainApprovalRequired(sourceHost: String?, targetHost: String)
    case companionUnavailable
    case userTakeover
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        case .tabNotFound:
            return NSLocalizedString("找不到指定的浏览器标签页。", comment: "Browser Agent tab not found")
        case .unsupported(let detail):
            return String(
                format: NSLocalizedString("当前设备不支持这项浏览器操作：%@", comment: "Browser Agent unsupported operation"),
                detail
            )
        case .navigationFailed(let detail):
            return String(
                format: NSLocalizedString("网页导航失败：%@", comment: "Browser Agent navigation failed"),
                detail
            )
        case .javaScriptFailed(let detail):
            return String(
                format: NSLocalizedString("网页操作失败：%@", comment: "Browser Agent JavaScript failed"),
                detail
            )
        case .crossDomainApprovalRequired(let sourceHost, let targetHost):
            return String(
                format: NSLocalizedString(
                    "网页尝试从 %@ 跳转到 %@。Agent 需要先对新域名单独发起获批的导航。",
                    comment: "Browser Agent unapproved cross-domain redirect"
                ),
                sourceHost ?? NSLocalizedString("未知域名", comment: "Unknown Browser Agent host"),
                targetHost
            )
        case .companionUnavailable:
            return NSLocalizedString("iPhone 当前不可达，无法委托浏览器操作。", comment: "Browser Agent iPhone unavailable")
        case .userTakeover:
            return NSLocalizedString("用户正在接管当前会话的浏览器，Agent 操作已暂停。", comment: "Browser Agent paused for user takeover")
        case .permissionDenied:
            return NSLocalizedString("用户未允许这项敏感浏览器操作。", comment: "Browser Agent elevated permission denied")
        }
    }
}

enum BrowserAgentToolDefinitions {
    static let toolName = "browser_control"

    static var all: [InternalToolDefinition] { [control] }

    static func contains(_ name: String) -> Bool {
        name == toolName
    }

    private static var control: InternalToolDefinition {
        InternalToolDefinition(
            name: toolName,
            description: NSLocalizedString(
                "控制当前聊天会话隔离的浏览器：管理标签页、导航、读取结构化页面、交互、截图与下载。先调用 capabilities 获取当前设备的准确能力；不会在不支持时伪装成功。",
                comment: "Browser Agent tool description"
            ),
            parameters: .dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "action": enumProperty(BrowserAgentAction.allCases.map(\.rawValue), NSLocalizedString("要执行的浏览器操作。", comment: "Browser Agent action")),
                    "tab_id": stringProperty(NSLocalizedString("目标标签页 UUID；部分操作省略时使用当前标签页。", comment: "Browser Agent tab ID")),
                    "url": stringProperty(NSLocalizedString("open_tab、navigate 或 download 的 URL。", comment: "Browser Agent URL")),
                    "element_index": integerProperty(NSLocalizedString("snapshot 返回的可交互元素编号。", comment: "Browser Agent element index")),
                    "text": stringProperty(NSLocalizedString("type 操作写入的文本。", comment: "Browser Agent input text")),
                    "submit": boolProperty(NSLocalizedString("输入后是否提交所在表单。", comment: "Browser Agent submit input")),
                    "delta_x": numberProperty(NSLocalizedString("横向滚动量。", comment: "Browser Agent horizontal scroll")),
                    "delta_y": numberProperty(NSLocalizedString("纵向滚动量。", comment: "Browser Agent vertical scroll")),
                    "script": stringProperty(NSLocalizedString("evaluate_javascript 执行的脚本。", comment: "Browser Agent JavaScript")),
                    "filename": stringProperty(NSLocalizedString("可选下载文件名。", comment: "Browser Agent download filename"))
                ]),
                "required": .array([.string("action")])
            ]),
            isBlocking: true
        )
    }

    private static func stringProperty(_ description: String) -> JSONValue {
        .dictionary(["type": .string("string"), "description": .string(description)])
    }

    private static func integerProperty(_ description: String) -> JSONValue {
        .dictionary(["type": .string("integer"), "minimum": .int(0), "description": .string(description)])
    }

    private static func numberProperty(_ description: String) -> JSONValue {
        .dictionary(["type": .string("number"), "description": .string(description)])
    }

    private static func boolProperty(_ description: String) -> JSONValue {
        .dictionary(["type": .string("boolean"), "description": .string(description)])
    }

    private static func enumProperty(_ values: [String], _ description: String) -> JSONValue {
        .dictionary([
            "type": .string("string"),
            "enum": .array(values.map { .string($0) }),
            "description": .string(description)
        ])
    }
}
