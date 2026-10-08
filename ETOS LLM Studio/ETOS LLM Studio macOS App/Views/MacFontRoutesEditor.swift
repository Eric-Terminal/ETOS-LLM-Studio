import ETOSCore
import SwiftUI

struct MacFontRoutesEditor: View {
    @ObservedObject var model: MacFontModel
    @StateObject private var draft: MacFontDraft
    let original: MacFontCatalog
    let epoch: UUID
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var visible = false
    @State private var editing: RuleTarget?
    private struct RuleTarget: Identifiable { let id = UUID(); let rule: ChatAppearanceTextFontRule; let chain: MacFontDraftCatalog.Chain }
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended && model.epoch == epoch }

    init(model: MacFontModel, original: MacFontCatalog, epoch: UUID, isActive: Bool) {
        self.model = model; self.original = original; self.epoch = epoch; self.isActive = isActive
        _draft = StateObject(wrappedValue: MacFontDraft(original))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "font-routes", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac 字体优先级使用说明", comment: ""), documentID: "settings-display", isActive: available)
                    ForEach(FontSemanticRole.allCases) { role in
                        NavigationLink(role.title) {
                            if let chain = draft.catalog?.roles[role] {
                                MacFontChainEditor(id: "role-\(role.rawValue)-\(epoch)", title: role.title, chain: chain,
                                    revision: draft.revision, isActive: available && !model.isWorking && editing == nil,
                                    isWorking: draft.isWorking, isCurrent: {
                                        draft.revision == $0 && !draft.isWorking && model.epoch == epoch && !model.isSuspended
                                    }) { ids in
                                        draft.change { $0.setChain(ids, for: role) }; await draft.waitForPendingChanges()
                                    }
                            }
                        }
                    }
                } header: { Text(NSLocalizedString("样式优先级", comment: "")) }
                if let catalog = draft.catalog {
                    Section {
                        ForEach(catalog.rules) { rule in
                            Button(rule.title.isEmpty ? NSLocalizedString("字体规则", comment: "") : rule.title) {
                                if let chain = catalog.ruleChains[rule.id] { editing = .init(rule: rule.value, chain: chain) }
                            }
                            .contextMenu {
                                Button(NSLocalizedString("上移", comment: "")) { move(rule.id, offset: -1) }
                                Button(NSLocalizedString("下移", comment: "")) { move(rule.id, offset: 1) }
                                Button(NSLocalizedString("删除", comment: ""), role: .destructive) { draft.change { $0.customTextRules.removeAll { $0.id == rule.id } } }
                            }
                        }
                        Button(NSLocalizedString("添加字体规则", comment: "")) { editing = .init(rule: .init(), chain: catalog.emptyChain) }
                    } header: { Text(NSLocalizedString("指定内容字体", comment: "")) } footer: {
                        Text(NSLocalizedString("规则按从上到下的顺序匹配；靠前规则优先。命中内容使用规则内部的字体优先级，其他内容继续使用外层全局字体。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if draft.isWorking { ProgressView() }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped).navigationTitle(NSLocalizedString("字体样式优先级", comment: ""))
            .onAppear { visible = true }.onDisappear { visible = false }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-font-routes-\(epoch)"), title: NSLocalizedString("字体样式优先级", comment: ""),
                documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")],
                isActive: available && visible && !draft.isWorking && !model.isWorking && editing == nil, settings: [
                    .readOnly("fonts", label: NSLocalizedString("字体文件", comment: ""), value: { original.guideValue }),
                    .readOnly("rule_count", label: NSLocalizedString("指定内容字体", comment: ""), value: { .int(draft.routes.customTextRules.count) }),
                    .readOnly("requires_navigation", label: NSLocalizedString("样式优先级", comment: ""), value: { .bool(true) }),
                    .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) })
                ])
        }
        .disabled(!available || model.isWorking || draft.isWorking)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(model.isWorking) }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "")) {
                    Task { if await model.save(draft.routes, original: original.snapshot, expectedEpoch: epoch) { dismiss() } }
                }.disabled(!available || !model.canEdit || draft.isWorking || editing != nil)
            }
        }
        .sheet(item: $editing) { target in
            MacFontRuleEditor(rule: target.rule, chain: target.chain, assets: original.assets, isActive: available) { draft.setRule($0) }
        }
        .onChange(of: available) { _, value in if !value { editing = nil } }
        .modifier(MacGuideInspector()).frame(minWidth: 540, minHeight: 560).interactiveDismissDisabled(model.isWorking)
    }
    private func move(_ id: String, offset: Int) {
        draft.change {
            guard let index = $0.customTextRules.firstIndex(where: { $0.id == id }), $0.customTextRules.indices.contains(index + offset) else { return }
            $0.customTextRules.swapAt(index, index + offset)
        }
    }
}
