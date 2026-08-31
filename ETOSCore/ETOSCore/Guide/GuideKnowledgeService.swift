// ============================================================================
// GuideKnowledgeService.swift
// ============================================================================
// ETOS LLM Studio
//
// 小而稳定的内置文档索引。全文搜索在 actor 中执行，不进入 SwiftUI 渲染链路。
// ============================================================================

import Foundation

public struct GuideDocument: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let keywords: [String]
    public let content: String

    public init(id: String, title: String, keywords: [String], content: String) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.content = content
    }
}

public actor GuideKnowledgeService {
    public static let shared = GuideKnowledgeService()

    private let documents: [GuideDocument]
    private let documentsByID: [String: GuideDocument]

    public init(documents: [GuideDocument] = GuideDocumentCatalog.documents) {
        self.documents = documents
        self.documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
    }

    public func search(_ query: String, limit: Int = 6) -> [GuideDocumentReference] {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        return documents
            .compactMap { document -> (GuideDocument, Int)? in
                let title = document.title.lowercased()
                let keywords = document.keywords.joined(separator: " ").lowercased()
                let body = document.content.lowercased()
                let score = terms.reduce(into: 0) { result, term in
                    if title.contains(term) { result += 8 }
                    if keywords.contains(term) { result += 4 }
                    if body.contains(term) { result += 1 }
                }
                return score > 0 ? (document, score) : nil
            }
            .sorted {
                if $0.1 == $1.1 { return $0.0.id < $1.0.id }
                return $0.1 > $1.1
            }
            .prefix(max(1, limit))
            .map { GuideDocumentReference(id: $0.0.id, title: $0.0.title) }
    }

    public func document(id: String) -> GuideDocument? {
        documentsByID[id]
    }
}

public enum GuideDocumentCatalog {
    public static let documents: [GuideDocument] = [
        GuideDocument(
            id: "guide-overview",
            title: "页面向导与隐私边界",
            keywords: ["向导", "浮球", "隐私", "上下文", "清空", "API Key"],
            content: """
            页面向导只在设置与配置页面工作。iPhone 上开启“在设置中显示页面向导”后会出现可拖动的向导按钮；Apple Watch 从设置列表进入向导页面。向导对话只保存在内存中，退出进程后自动消失，也可以随时一键清空。

            每次发送问题时，当前页面会显式提供页面标识、相关文档、允许读取的配置快照和本页专属工具。已有 API Key、密码与令牌永远不会发给模型，只显示为隐藏状态；模型可以提出写入新值的方案，但任何持久化修改都必须先经过原生确认预览。

            内置免费向导始终可用；用户也可以选择自己已配置且支持工具调用的聊天模型。两条线路不会静默切换，用户模型失败时会明确提供使用内置向导重试的操作。
            """
        ),
        GuideDocument(
            id: "provider-model-basics",
            title: "提供商、API 凭据与聊天模型",
            keywords: ["提供商", "模型", "API", "Key", "激活", "选择", "Base URL"],
            content: """
            可聊天状态需要同时满足：存在提供商；需要凭据的远程提供商已经填写 API Key；提供商下存在聊天模型；模型已经激活；最后有一个可运行聊天模型被选中。向导根据真实状态显示缺少哪一步，不保存“已经看过欢迎页”之类的标记。

            提供商负责 Base URL、API 格式、请求路径、凭据和独立代理；模型负责模型名、显示名、能力、激活状态及请求体覆盖。只有模型明确启用了“工具调用”能力时，才可被选作用户自有向导模型。

            在提供商的“模型配置”页面，向导可以按模型 ID 提交结构化 JSON，新增模型或只更新指定字段。模型 ID 是合并键；省略的字段会保留原值，新增或更新的模型会加入“已添加”列表。删除必须由用户明确提出，并且所有变更都会先显示原生确认预览，确认后才保存。

            测试连接不会替代保存。编辑完成后先执行原生连接测试，再在最终预览中确认提供商与模型配置，最后一次性保存并选中，避免产生半配置状态。
            """
        ),
        GuideDocument(
            id: "model-request-body",
            title: "模型请求体与结构化控制",
            keywords: ["请求体", "JSON", "结构化", "覆盖", "temperature", "参数", "control"],
            content: """
            模型的请求体配置分为键值控制与原始 JSON 两种方式。键值控制适合把常用参数公开成开关、输入框、枚举或滑块；原始 JSON 适合上游需要复杂嵌套结构时整体覆盖。

            模型级覆盖优先于全局 temperature、top_p 等默认参数。切换模式前应确认另一种模式中的草稿是否仍需保留。向导提出结构化修改时会展示字段路径、原值与新值；确认前不会写入模型配置。
            """
        ),
        GuideDocument(
            id: "network-proxy",
            title: "全局代理与提供商独立代理",
            keywords: ["代理", "HTTP", "SOCKS5", "网络", "密码", "端口"],
            content: """
            提供商独立代理优先于全局代理；没有独立配置时才使用全局代理。HTTP 与 SOCKS5 都需要有效主机和 1 到 65535 的端口。代理用户名与密码属于敏感字段，向导只能知道是否已填写，不能读取已有内容。

            修改代理后应使用对应模型的连接测试验证。关闭代理不会删除已填写的主机与凭据，重新开启时可以继续使用。
            """
        ),
        GuideDocument(
            id: "mcp-tools",
            title: "MCP 工具接入与聊天工具开关",
            keywords: ["MCP", "工具", "服务器", "stdio", "HTTP", "审批"],
            content: """
            MCP 服务器配置与“加入聊天工具”是两件事：服务器可以已经保存但尚未连接，也可以已连接但没有加入普通聊天。页面向导可以按当前页面声明创建 HTTP、SSE 或本地 stdio MCP Server；它会先生成原生配置预览，只有用户确认后才保存。认证头和环境变量会在预览中脱敏，已有秘密仍不可读取。

            页面向导的专属工具与 MCP 完全隔离，不会出现在 MCP 列表或普通聊天的工具定义中。页面还可以显式声明自己的只读或变更工具，由所属页面负责校验和执行；服务端不会用固定工具名单阻止这些自定义能力。

            本地 stdio 需要本地 Linux 运行环境；远程服务器按其传输协议填写地址与认证信息。涉及副作用的工具仍受工具审批策略控制。
            """
        ),
        GuideDocument(
            id: "first-model-setup",
            title: "首次配置模型的状态式引导",
            keywords: ["首次", "初始化", "云端", "自定义", "本地", "导入", "配置"],
            content: """
            没有可运行聊天模型时，聊天页、模型选择器和模型管理页会显示同一套状态式引导。用户可以选择云端模板、自定义 OpenAI 兼容服务、本地模型或导入配置；第一屏只解释选择，不立即请求模型。

            配置草稿仅保存在内存中。API Key 通过原生安全输入框直接交给凭据存储，不进入向导上下文。完成原生连接测试后，最终确认会原子地保存提供商、模型、激活状态和当前选择。
            """
        )
    ]
}
