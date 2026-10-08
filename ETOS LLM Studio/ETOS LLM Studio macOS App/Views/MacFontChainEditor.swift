import ETOSCore
import SwiftUI

struct MacFontChainEditor: View {
    let id: String
    let title: String
    let chain: MacFontDraftCatalog.Chain
    let revision: UUID
    let isActive: Bool
    let isWorking: Bool
    let isCurrent: @MainActor (UUID) -> Bool
    let replace: @MainActor ([UUID]) async -> Void
    @State private var visible = false
    private var pageID: GuidePageID { GuidePageID(rawValue: "mac-font-chain-\(id)-\(revision)") }
    private static var tool: InternalToolDefinition { InternalToolDefinition(name: "propose_mac_font_priority", description: NSLocalizedString("字体优先级", comment: ""),
        parameters: .dictionary(["type": .string("object"), "properties": .dictionary([
            "font_ids": .dictionary(["type": .string("array"), "items": .dictionary(["type": .string("string")]), "uniqueItems": .bool(true)])
        ]), "required": .array([.string("font_ids")]), "additionalProperties": .bool(false)])) }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "font-chain-\(id)", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 字体优先级使用说明", comment: ""), documentID: "settings-display", isActive: isActive)
                if chain.selected.isEmpty {
                    Text(NSLocalizedString("当前槽位没有可用字体，将使用系统默认字体。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(chain.selected) { asset in
                    HStack {
                        Text(asset.displayName)
                        Spacer()
                        Button { move(asset.id, -1) } label: { Label(NSLocalizedString("上移", comment: ""), systemImage: "arrow.up") }
                        Button { move(asset.id, 1) } label: { Label(NSLocalizedString("下移", comment: ""), systemImage: "arrow.down") }
                        Button { change { $0.removeAll { $0 == asset.id } } } label: { Label(NSLocalizedString("移除", comment: ""), systemImage: "minus.circle") }
                    }.buttonStyle(.borderless)
                }
            } header: { Text(NSLocalizedString("字体优先级", comment: "")) }
            Section {
                ForEach(chain.available) { asset in Button(asset.displayName) { change { $0.append(asset.id) } } }
            } header: { Text(NSLocalizedString("添加字体到当前槽位", comment: "")) }
        }
        .formStyle(.grouped).navigationTitle(title).disabled(!isActive || isWorking)
        .onAppear { visible = true }.onDisappear { visible = false }
        .guidePageContext(descriptor: GuidePageDescriptor(id: pageID, title: title,
            documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")],
            tools: isWorking ? [] : [GuidePageTool(definition: Self.tool, access: .proposeChange)]), isActive: isActive && visible,
            snapshot: { GuidePageSnapshot(fields: [
                "font_ids": GuideSnapshotField(label: NSLocalizedString("字体优先级", comment: ""), value: chain.guideValue),
                "available_fonts": GuideSnapshotField(label: NSLocalizedString("字体文件", comment: ""), value: chain.availableGuide, access: .readOnly),
                "requires_save": GuideSnapshotField(label: NSLocalizedString("修改后需要保存", comment: ""), value: .bool(true), access: .readOnly)
            ]) }, buildProposal: { call, _ in
                guard isActive, visible, !isWorking, call.toolName == Self.tool.name else { throw GuideError.pageChanged }
                let expected = revision, allowed = chain.allowedIDs
                let value = try await Task.detached {
                    let args = try GuideToolArguments.decode(call.arguments)
                    try GuideToolArguments.requireOnlyKeys(["font_ids"], in: args)
                    let ids = try Self.ids(args["font_ids"], allowed: allowed)
                    return JSONValue.array(ids.map { .string($0.uuidString) })
                }.value
                guard isActive, visible, isCurrent(expected) else { throw GuideError.pageChanged }
                return GuideActionProposal(pageID: pageID, toolCallID: call.id, toolName: call.toolName, summary: NSLocalizedString("字体优先级", comment: ""),
                    mutations: [GuideSettingMutation(path: "font_ids", label: NSLocalizedString("字体优先级", comment: ""), oldValue: chain.guideValue, newValue: value)],
                    arguments: ["font_ids": value, "revision": .string(expected.uuidString)])
            }, execute: { proposal in
                guard isActive, visible, isCurrent(revision), proposal.toolName == Self.tool.name,
                      try GuideToolArguments.string("revision", in: proposal.arguments) == revision.uuidString else { throw GuideError.pageChanged }
                let expected = revision, allowed = chain.allowedIDs, value = proposal.arguments["font_ids"]
                let ids = try await Task.detached { try Self.ids(value, allowed: allowed) }.value
                guard isActive, visible, isCurrent(expected) else { throw GuideError.pageChanged }
                await replace(ids)
                return GuideActionExecution(message: NSLocalizedString("已更新草稿，请保存配置以生效。", comment: ""))
            })
    }
    private func move(_ id: UUID, _ offset: Int) {
        change { ids in
            guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
            ids.swapAt(index, index + offset)
        }
    }
    private func change(_ mutation: @escaping @Sendable (inout [UUID]) -> Void) {
        let records = chain.selected, expected = revision
        Task {
            let ids = await Task.detached { var ids = records.map(\.id); mutation(&ids); return ids }.value
            guard isActive, visible, isCurrent(expected) else { return }
            await replace(ids)
        }
    }
    nonisolated static func ids(_ value: JSONValue?, allowed: Set<UUID>) throws -> [UUID] {
        guard case .array(let items)? = value else { throw GuideError.invalidToolArguments }
        var seen = Set<UUID>()
        return try items.map {
            guard case .string(let raw) = $0, let id = UUID(uuidString: raw), allowed.contains(id), seen.insert(id).inserted else { throw GuideError.invalidToolArguments }
            return id
        }
    }
}
