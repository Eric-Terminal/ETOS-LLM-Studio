import ETOSCore
import SwiftUI

struct MacToolCenterView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "tool-center", title: NSLocalizedString("使用说明", comment: ""),
                                     details: NSLocalizedString("Mac 工具中心使用说明", comment: ""),
                                     documentID: "settings-tools", isActive: isActive)
            }
            Section {
                NavigationLink {
                    MacBuiltInToolsView(isActive: isActive, model: workspace.builtInTools)
                } label: { Label(NSLocalizedString("内置工具", comment: ""), systemImage: "app.badge") }
                NavigationLink {
                    MacMCPListView(isActive: isActive)
                } label: { Label(NSLocalizedString("MCP 工具", comment: ""), systemImage: "puzzlepiece.extension") }
                NavigationLink {
                    MacShortcutToolsView(isActive: isActive, model: workspace.shortcutTools)
                } label: { Label(NSLocalizedString("快捷指令工具", comment: ""), systemImage: "square.stack.3d.up") }
                NavigationLink {
                    MacSkillsView(isActive: isActive, model: workspace.skills)
                } label: { Label(NSLocalizedString("Agent Skills", comment: ""), systemImage: "books.vertical") }
                NavigationLink {
                    MacAgentPromptsView(isActive: isActive, model: workspace.agentPrompts)
                } label: { Label(NSLocalizedString("Agent 提示词", comment: ""), systemImage: "text.bubble") }
                NavigationLink {
                    MacBrowserView(sessionID: workspace.currentSession?.id, isTemporary: workspace.temporaryChatMemoryMode != nil,
                                   isActive: isActive && workspace.canManageLocalModels, model: workspace.browser)
                } label: { Label(NSLocalizedString("浏览器", comment: ""), systemImage: "safari") }
            }
            Section {
                NavigationLink {
                    MacToolApprovalSettingsView(isActive: isActive, model: workspace.toolApproval)
                } label: { Label(NSLocalizedString("审批自动化", comment: ""), systemImage: "hand.raised") }
            }
        }
        .navigationTitle(NSLocalizedString("工具中心", comment: ""))
        .guideSettingsPageContext(
            id: "mac-tool-center", title: NSLocalizedString("工具中心", comment: ""),
            documents: [GuideDocumentReference(id: "settings-tools", title: "Tool Center"),
                        GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: isActive && workspace.canManageLocalModels,
            settings: [
                .readOnly("built_in_requires_navigation", label: NSLocalizedString("内置工具", comment: ""), value: { .bool(true) }),
                .readOnly("mcp_requires_navigation", label: NSLocalizedString("MCP 工具", comment: ""), value: { .bool(true) }),
                .readOnly("shortcuts_requires_navigation", label: NSLocalizedString("快捷指令工具", comment: ""), value: { .bool(true) }),
                .readOnly("skills_requires_navigation", label: NSLocalizedString("Agent Skills", comment: ""), value: { .bool(true) }),
                .readOnly("agent_prompts_requires_navigation", label: NSLocalizedString("Agent 提示词", comment: ""), value: { .bool(true) }),
                .readOnly("browser_requires_navigation", label: NSLocalizedString("浏览器", comment: ""), value: { .bool(true) }),
                .readOnly("approval_requires_navigation", label: NSLocalizedString("审批自动化", comment: ""), value: { .bool(true) })
            ]
        )
    }
}
