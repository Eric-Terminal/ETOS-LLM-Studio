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
    case getText = "get_text"
    case getPageInfo = "get_page_info"
    case findElements = "find_elements"
    case click
    case type
    case hover
    case scroll
    case scrollAndCollect = "scroll_and_collect"
    case waitForDOMStable = "wait_for_dom_stable"
    case getReadable = "get_readable"
    case getBackbone = "get_backbone"
    case setUserAgent = "set_user_agent"
    case setViewport = "set_viewport"
    case evaluateJavaScript = "evaluate_javascript"
    case screenshot
    case fetch
    case download
    case closeTab = "close_tab"
}

public enum BrowserAgentUserAgentProfile: String, Codable, CaseIterable, Sendable {
    case mobileSafari = "mobile_safari"
    case desktopSafari = "desktop_safari"
    case reset
}

public enum BrowserAgentController: String, Codable, Sendable {
    case idle
    case agent
    case user
    case returningToAgent = "returning_to_agent"
}

public enum BrowserAgentControlStatus: String, Codable, Sendable {
    case idle
    case running
    case waiting
    case completed
    case failed
    case interrupted
}

public struct BrowserAgentControlState: Codable, Equatable, Sendable {
    public let controller: BrowserAgentController
    public let status: BrowserAgentControlStatus
    public let action: BrowserAgentAction?
    public let tabID: UUID?
    public let domain: String?
    public let detail: String?
    public let startedAt: Date?

    public init(
        controller: BrowserAgentController = .idle,
        status: BrowserAgentControlStatus = .idle,
        action: BrowserAgentAction? = nil,
        tabID: UUID? = nil,
        domain: String? = nil,
        detail: String? = nil,
        startedAt: Date? = nil
    ) {
        self.controller = controller
        self.status = status
        self.action = action
        self.tabID = tabID
        self.domain = domain
        self.detail = detail
        self.startedAt = startedAt
    }

    public static let idle = BrowserAgentControlState()
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
    public let supportedActions: [BrowserAgentAction]?

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
        notes: [String],
        supportedActions: [BrowserAgentAction] = BrowserAgentAction.allCases
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
        self.supportedActions = supportedActions
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
    public let domRevision: Int?
    public let userAgentProfile: BrowserAgentUserAgentProfile?
    public let viewportWidth: Int?
    public let viewportHeight: Int?
    public let lastActivityAt: Date?
    public let wasRestoredByReload: Bool?

    public init(
        id: UUID,
        title: String,
        url: String?,
        isLoading: Bool,
        domRevision: Int? = nil,
        userAgentProfile: BrowserAgentUserAgentProfile? = nil,
        viewportWidth: Int? = nil,
        viewportHeight: Int? = nil,
        lastActivityAt: Date? = nil,
        wasRestoredByReload: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.isLoading = isLoading
        self.domRevision = domRevision
        self.userAgentProfile = userAgentProfile
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.lastActivityAt = lastActivityAt
        self.wasRestoredByReload = wasRestoredByReload
    }
}

public struct BrowserAgentElementBounds: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct BrowserAgentSnapshot: Codable, Equatable, Sendable {
    public struct Element: Codable, Equatable, Sendable {
        public let index: Int
        public let elementID: String
        public let domRevision: Int
        public let role: String
        public let label: String
        public let text: String?
        public let value: String?
        public let isVisible: Bool
        public let bounds: BrowserAgentElementBounds
        public let actions: [String]

        public init(
            index: Int,
            elementID: String,
            domRevision: Int,
            role: String,
            label: String,
            text: String? = nil,
            value: String?,
            isVisible: Bool,
            bounds: BrowserAgentElementBounds,
            actions: [String]
        ) {
            self.index = index
            self.elementID = elementID
            self.domRevision = domRevision
            self.role = role
            self.label = label
            self.text = text
            self.value = value
            self.isVisible = isVisible
            self.bounds = bounds
            self.actions = actions
        }
    }

    public let title: String
    public let url: String?
    public let text: String
    public let elements: [Element]
    public let wasTruncated: Bool
    public let domRevision: Int

    public init(
        title: String,
        url: String?,
        text: String,
        elements: [Element],
        wasTruncated: Bool,
        domRevision: Int
    ) {
        self.title = title
        self.url = url
        self.text = text
        self.elements = elements
        self.wasTruncated = wasTruncated
        self.domRevision = domRevision
    }
}

public struct BrowserAgentPageInfo: Codable, Equatable, Sendable {
    public let title: String
    public let url: String?
    public let canonicalURL: String?
    public let language: String?
    public let contentType: String?
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let scrollWidth: Double
    public let scrollHeight: Double
    public let linkCount: Int
    public let formCount: Int
    public let domRevision: Int
}

public struct BrowserAgentReadableContent: Codable, Equatable, Sendable {
    public let title: String
    public let byline: String?
    public let publishedAt: String?
    public let text: String
    public let links: [String]
    public let wasTruncated: Bool
}

public struct BrowserAgentElementCollection: Codable, Equatable, Sendable {
    public let elements: [BrowserAgentSnapshot.Element]
    public let domRevision: Int
    public let wasTruncated: Bool

    public init(
        elements: [BrowserAgentSnapshot.Element],
        domRevision: Int,
        wasTruncated: Bool
    ) {
        self.elements = elements
        self.domRevision = domRevision
        self.wasTruncated = wasTruncated
    }
}

public struct BrowserAgentScreenshotResult: Codable, Equatable, Sendable {
    public let uri: String
    public let width: Int
    public let height: Int
    public let fullPage: Bool
    public let wasTruncated: Bool
}

public struct BrowserAgentDownloadResult: Codable, Equatable, Sendable {
    public let uri: String
    public let finalURL: String
    public let mimeType: String?
    public let filename: String
    public let byteCount: Int64
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
    case staleElement(expectedRevision: Int?, actualRevision: Int)
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
        case .staleElement(let expectedRevision, let actualRevision):
            return String(
                format: NSLocalizedString(
                    "页面结构已变化（请求版本 %@，当前版本 %d）；请重新调用 find_elements 或 snapshot。",
                    comment: "Browser Agent stale element"
                ),
                expectedRevision.map(String.init) ?? "-",
                actualRevision
            )
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
                "控制当前聊天会话隔离的浏览器：管理标签页、导航、读取与定位页面、等待动态内容、交互、当前会话下载和全页截图。先调用 capabilities 获取准确能力；不提供任何 Cookie 工具，也不会在不支持时伪装成功。",
                comment: "Browser Agent tool description"
            ),
            parameters: .dictionary([
                "type": .string("object"),
                "properties": .dictionary([
                    "action": enumProperty(BrowserAgentAction.allCases.map(\.rawValue), NSLocalizedString("要执行的浏览器操作。", comment: "Browser Agent action")),
                    "tab_id": stringProperty(NSLocalizedString("目标标签页 UUID；部分操作省略时使用当前标签页。", comment: "Browser Agent tab ID")),
                    "url": stringProperty(NSLocalizedString("open_tab、navigate、fetch 或 download 的 URL。", comment: "Browser Agent URL")),
                    "element_index": integerProperty(NSLocalizedString("snapshot 返回的可交互元素编号。", comment: "Browser Agent element index")),
                    "element_id": stringProperty(NSLocalizedString("find_elements 或 snapshot 返回的稳定元素 ID。", comment: "Browser Agent element ID")),
                    "dom_revision": integerProperty(NSLocalizedString("元素结果对应的 DOM revision；页面变化后必须重新定位。", comment: "Browser Agent DOM revision")),
                    "selector": stringProperty(NSLocalizedString("可选 CSS selector，用于限定读取、查找或收集范围。", comment: "Browser Agent selector")),
                    "text": stringProperty(NSLocalizedString("type 操作写入的文本。", comment: "Browser Agent input text")),
                    "submit": boolProperty(NSLocalizedString("输入后是否提交所在表单。", comment: "Browser Agent submit input")),
                    "delta_x": numberProperty(NSLocalizedString("横向滚动量。", comment: "Browser Agent horizontal scroll")),
                    "delta_y": numberProperty(NSLocalizedString("纵向滚动量。", comment: "Browser Agent vertical scroll")),
                    "script": stringProperty(NSLocalizedString("evaluate_javascript 执行的脚本。", comment: "Browser Agent JavaScript")),
                    "filename": stringProperty(NSLocalizedString("可选下载文件名。", comment: "Browser Agent download filename")),
                    "full_page": boolProperty(NSLocalizedString("截图时是否捕获完整滚动页面，默认 false。", comment: "Browser Agent full page screenshot")),
                    "user_agent": enumProperty(BrowserAgentUserAgentProfile.allCases.map(\.rawValue), NSLocalizedString("mobile_safari、desktop_safari 或 reset。", comment: "Browser Agent user agent profile")),
                    "viewport_width": integerProperty(NSLocalizedString("视口宽度，320 到 1920；必须与高度同时提供。", comment: "Browser Agent viewport width")),
                    "viewport_height": integerProperty(NSLocalizedString("视口高度，320 到 2160；必须与宽度同时提供。", comment: "Browser Agent viewport height")),
                    "reset": boolProperty(NSLocalizedString("重置当前标签页的视口或 User-Agent 覆盖。", comment: "Browser Agent reset override")),
                    "max_depth": integerProperty(NSLocalizedString("语义 DOM 最大深度，默认 5，最大 12。", comment: "Browser Agent backbone depth")),
                    "max_nodes": integerProperty(NSLocalizedString("语义 DOM 最大节点数，默认 300，最大 1000。", comment: "Browser Agent backbone nodes")),
                    "scroll_count": integerProperty(NSLocalizedString("滚动收集次数，默认 5，最大 20。", comment: "Browser Agent scroll count")),
                    "item_selector": stringProperty(NSLocalizedString("scroll_and_collect 的项目 selector。", comment: "Browser Agent item selector")),
                    "dedupe_key": stringProperty(NSLocalizedString("可选项目内 selector 或属性名，用于去重。", comment: "Browser Agent dedupe key")),
                    "timeout_seconds": numberProperty(NSLocalizedString("等待超时秒数，最大 30。", comment: "Browser Agent timeout")),
                    "quiet_period_seconds": numberProperty(NSLocalizedString("DOM 无变化的安静窗口秒数，默认 0.5。", comment: "Browser Agent DOM quiet period"))
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
