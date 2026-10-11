import ETOSCore
import SwiftUI

@MainActor
struct MacMessageActionBarSettingsView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @State private var draft = MessageActionBarConfiguration.defaultConfiguration
    @State private var original = ""
    @State private var role: MessageActionBarRole = .assistant
    @State private var availableItems: [MessageActionBarItem] = []
    @State private var visible = false
    @State private var isSaving = false
    @State private var revision = UUID()
    @State private var saving: Task<Void, Never>?
    private var available: Bool { isActive && workspace.canManageLocalModels && appLock.state != .locked }
    private var hasConflict: Bool { original != configuration.messageActionBarConfiguration }
    private var items: [MessageActionBarItem] { draft.items(for: role) }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "message-action-bar", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 消息功能栏使用说明", comment: ""), documentID: "settings-display", isActive: available)
                Picker(NSLocalizedString("消息类型", comment: ""), selection: $role) {
                    Text(NSLocalizedString("助手气泡", comment: "")).tag(MessageActionBarRole.assistant)
                    Text(NSLocalizedString("用户气泡", comment: "")).tag(MessageActionBarRole.user)
                }
                Picker(NSLocalizedString("功能栏位置", comment: ""), selection: Binding(
                    get: { draft.alignment(for: role) }, set: { draft.setAlignment($0, for: role) })) {
                    Text(NSLocalizedString("靠左延伸", comment: "")).tag(MessageActionBarAlignment.leading)
                    Text(NSLocalizedString("靠右延伸", comment: "")).tag(MessageActionBarAlignment.trailing)
                }
                Toggle(NSLocalizedString("显示外围边框", comment: ""), isOn: $draft.showsOuterBorder)
                Slider(value: $draft.fontScale, in: FontLibrary.minimumFontScale...FontLibrary.maximumFontScale, step: 0.05) {
                    Text(String(format: NSLocalizedString("字体缩放 %.0f%%", comment: ""), draft.fontScale * 100))
                }
                Button(NSLocalizedString("恢复默认字号", comment: "")) { draft.fontScale = FontLibrary.defaultFontScale }
            }
            Section {
                if items.isEmpty { Text(NSLocalizedString("当前没有启用的项目", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                ForEach(items) { item in
                    HStack {
                        Label(item.macTitle, systemImage: item.macSymbol)
                        Spacer()
                        Button { move(item, by: -1) } label: { Image(systemName: "arrow.up") }
                            .help(NSLocalizedString("上移", comment: "")).accessibilityLabel(NSLocalizedString("上移", comment: ""))
                            .disabled(items.first == item)
                        Button { move(item, by: 1) } label: { Image(systemName: "arrow.down") }
                            .help(NSLocalizedString("下移", comment: "")).accessibilityLabel(NSLocalizedString("下移", comment: ""))
                            .disabled(items.last == item)
                        Button { draft.setItems(items.filter { $0 != item }, for: role) } label: { Image(systemName: "minus.circle") }
                            .help(NSLocalizedString("移除", comment: "")).accessibilityLabel(NSLocalizedString("移除", comment: ""))
                    }
                    .buttonStyle(.borderless)
                }
            } header: { Text(NSLocalizedString("已启用项目", comment: "")) } footer: {
                Text(NSLocalizedString("助手气泡和用户气泡可以分别配置。列表从上到下对应气泡下方从左到右或从右到左的显示顺序。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                ForEach(availableItems) { item in
                    Button { draft.setItems(items + [item], for: role) } label: { Label(item.macTitle, systemImage: "plus.circle") }
                }
            } header: { Text(NSLocalizedString("可添加项目", comment: "")) }
            Section {
                if hasConflict {
                    Text(NSLocalizedString("功能栏配置已在其他位置更改，请重新载入后编辑。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(NSLocalizedString("重新载入", comment: "")) { reload() }
                }
                Button(NSLocalizedString("保存", comment: "")) { save() }
                    .disabled(hasConflict || draft == configuration.messageActionBarSettings)
                if isSaving { ProgressView().controlSize(.small) }
            } footer: {
                Text(NSLocalizedString("修改仅保留在草稿中，点击保存后应用。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("功能栏自定义", comment: ""))
        .disabled(!available || isSaving)
        .onAppear { visible = true; reload() }
        .onDisappear { visible = false; cancelSave() }
        .onChange(of: available) { _, active in if !active { cancelSave() } }
        .onChange(of: configuration.messageActionBarConfiguration) { _, _ in cancelSave() }
        .onChange(of: draft) { _, _ in refreshItems() }
        .onChange(of: role) { _, _ in refreshItems(); revision = UUID() }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-message-action-bar-\(role.rawValue)-\(revision)"),
            title: NSLocalizedString("功能栏自定义", comment: ""),
            documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings"),
                        GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: available && visible && !isSaving && !hasConflict,
            settings: [
                .readOnly("editing_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("manual_draft_until_save") }),
                .readOnly("message_role", label: NSLocalizedString("消息类型", comment: ""), value: { .string(role.rawValue) }),
                .string("alignment", label: NSLocalizedString("功能栏位置", comment: ""), allowedValues: ["leading", "trailing"],
                        get: { draft.alignment(for: role).rawValue },
                        set: { if let value = MessageActionBarAlignment(rawValue: $0) { draft.setAlignment(value, for: role) } }),
                .bool("outer_border", label: NSLocalizedString("显示外围边框", comment: ""),
                      get: { draft.showsOuterBorder }, set: { draft.showsOuterBorder = $0 }),
                .double("font_scale", label: NSLocalizedString("功能栏字号", comment: ""), range: FontLibrary.minimumFontScale...FontLibrary.maximumFontScale,
                        get: { draft.fontScale }, set: { draft.fontScale = FontLibrary.normalizedFontScale($0) }),
                .json("items", label: NSLocalizedString("已启用项目", comment: ""),
                      schema: GuideDisplayActionSettingsSupport.messageActionItemsSchema(for: role),
                      get: { GuideDisplayActionSettingsSupport.messageActionItemsValue(items) },
                      normalize: { try GuideDisplayActionSettingsSupport.normalizeMessageActionItems($0) },
                      set: { value in
                          let items = try GuideDisplayActionSettingsSupport.messageActionItems(from: value)
                          let supported = Set(MessageActionBarItem.supportedItems(for: role))
                          guard items.allSatisfy(supported.contains) else { throw GuideError.invalidToolArguments }
                          draft.setItems(items, for: role)
                      })
            ])
    }

    private func refreshItems() {
        availableItems = MessageActionBarItem.supportedItems(for: role).filter { !items.contains($0) }
    }

    private func move(_ item: MessageActionBarItem, by offset: Int) {
        guard let index = items.firstIndex(of: item), items.indices.contains(index + offset) else { return }
        var reordered = items
        reordered.swapAt(index, index + offset)
        draft.setItems(reordered, for: role)
    }

    private func reload() {
        draft = configuration.messageActionBarSettings
        original = configuration.messageActionBarConfiguration
        revision = UUID(); refreshItems()
    }

    private func cancelSave() { saving?.cancel(); saving = nil; isSaving = false; revision = UUID() }

    private func save() {
        guard visible, available, !isSaving, !hasConflict else { return }
        isSaving = true
        let pending = draft, expected = original, revision = revision
        saving = Task {
            // 编码没有副作用；离页、锁定或外部配置变化后，迟到结果不能写入数据库。
            let prepared = await Task.detached(priority: .userInitiated) { PreparedMessageActionBarConfiguration(pending) }.value
            guard !Task.isCancelled else { return }
            guard visible, available, self.revision == revision,
                  configuration.messageActionBarConfiguration == expected else { isSaving = false; return }
            configuration.applyPreparedMessageActionBarSettings(prepared)
            isSaving = false; reload()
        }
    }
}
