import Foundation
import Combine

extension AppToolKind {
    var builtInDescriptionPromptID: BuiltInPromptID? {
        switch self {
        case .showWidget: .showWidgetToolDescription
        case .askUserInput: .askUserInputToolDescription
        case .getSystemTime: .getSystemTimeToolDescription
        default: nil
        }
    }
}

public enum ToolDescriptionTarget: Identifiable {
    case builtIn(BuiltInPromptID)
    case mcp(serverID: UUID, tool: MCPToolDescription)

    public var id: String {
        switch self {
        case .builtIn(let id): "built-in-\(id.rawValue)"
        case .mcp(let serverID, let tool): "mcp-\(serverID.uuidString)-\(tool.toolId)"
        }
    }
}

struct ToolDescriptionRow: Identifiable {
    let target: ToolDescriptionTarget
    let title: String
    let isCustomized: Bool
    var id: String { target.id }
}

struct ToolDescriptionGroup: Identifiable {
    let id: String
    let title: String
    let rows: [ToolDescriptionRow]
}

@MainActor
extension MCPManager {
    /// 目录在页面任务中准备，编辑未连接的内置工具也无需启动服务器。
    func builtInToolDescriptionGroups() -> [ToolDescriptionGroup] {
        servers.compactMap { server in
            let descriptions: [MCPToolDescription]
            switch server.transport {
            case .builtInAppTool(let category):
                descriptions = MCPBuiltInAppToolServer.appToolDescriptions(for: category)
            case .builtInPersonalData:
                descriptions = MCPBuiltInPersonalDataServer.toolDescriptions()
            case .builtInSearch:
                descriptions = [MCPToolDescription(
                    toolId: MCPBuiltInSearchServer.toolID,
                    description: MCPBuiltInSearchServer.toolDescription,
                    inputSchema: nil
                )]
            default:
                return nil
            }
            return ToolDescriptionGroup(id: server.id.uuidString, title: server.displayName, rows: descriptions.map { tool in
                ToolDescriptionRow(
                    target: .mcp(serverID: server.id, tool: tool),
                    title: AppToolKind.resolve(from: tool.toolId)?.displayName ?? tool.toolId,
                    isCustomized: server.toolDescriptionOverrides[tool.toolId] != nil
                )
            })
        }
    }
}

/// 编辑草稿与持久化快照分开：向导只改草稿，原生保存才会影响后续请求。
@MainActor
final class ToolDescriptionEditorModel: ObservableObject {
    let target: ToolDescriptionTarget
    @Published var draft = ""
    @Published var usesDefault = true
    @Published private(set) var title = ""
    @Published private(set) var defaultDescription = ""
    @Published private(set) var inputSchema: JSONValue = .null
    @Published private(set) var isLoaded = false
    @Published private(set) var isSaving = false
    @Published private(set) var statusText: String?
    private var originalServer: MCPServerConfiguration?

    init(target: ToolDescriptionTarget) { self.target = target }

    func load() async {
        switch target {
        case .builtIn(let id):
            let snapshot = await Task.detached(priority: .utility) { BuiltInPromptStore.snapshot(for: id) }.value
            title = snapshot.title
            defaultDescription = snapshot.defaultTemplate
            draft = snapshot.currentTemplate
            usesDefault = !snapshot.isCustomized
        case .mcp(let serverID, let sourceTool):
            await MCPManager.shared.waitForInitialLoadIfNeeded()
            guard let server = MCPManager.shared.servers.first(where: { $0.id == serverID }) else {
                isLoaded = false
                statusText = NSLocalizedString("服务器已移除", comment: "")
                return
            }
            originalServer = server
            let tool = MCPManager.shared.status(for: server).tools.first(where: { $0.toolId == sourceTool.toolId }) ?? sourceTool
            title = tool.toolId
            defaultDescription = tool.description ?? ""
            inputSchema = tool.inputSchema ?? .null
            draft = server.effectiveDescription(for: tool) ?? ""
            usesDefault = server.toolDescriptionOverrides[tool.toolId] == nil
        }
        isLoaded = true
    }

    func save() async {
        guard isLoaded, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            switch target {
            case .builtIn(let id):
                let draft = draft
                let usesDefault = usesDefault
                let saved = await Task.detached(priority: .utility) {
                    usesDefault ? BuiltInPromptStore.resetTemplate(for: id) : BuiltInPromptStore.saveTemplate(draft, for: id)
                }.value
                guard saved else { throw MCPConfigurationWriteError.persistenceFailed }
            case .mcp(_, let tool):
                guard let originalServer else { throw MCPConfigurationWriteError.changedExternally }
                var updated = originalServer
                // 即使服务器没有描述，显式保存空值也要覆盖请求层的后备说明。
                updated.toolDescriptionOverrides[tool.toolId] = usesDefault ? nil : draft
                try await MCPManager.shared.saveServerInBackground(updated, replacing: originalServer)
            }
            await load()
            statusText = NSLocalizedString("已保存提示词设置。", comment: "")
        } catch {
            statusText = error.localizedDescription
        }
    }
}
