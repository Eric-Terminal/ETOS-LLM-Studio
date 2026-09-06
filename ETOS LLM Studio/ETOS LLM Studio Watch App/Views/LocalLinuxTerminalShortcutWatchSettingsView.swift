// ============================================================================
// LocalLinuxTerminalShortcutWatchSettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 端本地 Linux 终端快捷栏设置。
// ============================================================================

import ETOSCore
import SwiftUI

struct LocalLinuxTerminalShortcutWatchSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var selectedShortcuts = LocalLinuxTerminalShortcutConfiguration.defaults

    var body: some View {
        List {
            Section {
                if selectedShortcuts.isEmpty {
                    Text(NSLocalizedString("还没有选择终端快捷键。", comment: "Watch 终端快捷键空状态"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shortcutsBinding, id: \.id, editActions: .move) { $shortcut in
                        NavigationLink {
                            LocalLinuxTerminalShortcutWatchEditorView(shortcut: shortcut) { updated in
                                replaceShortcut(id: shortcut.id, with: updated)
                            }
                        } label: {
                            Text(shortcut.title)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                removeShortcut(id: shortcut.id)
                            } label: {
                                Label(NSLocalizedString("删除", comment: "Watch 删除终端快捷键"), systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("已显示的按键", comment: "Watch 终端快捷键已选择分区"))
            } footer: {
                Text(NSLocalizedString("长按拖动排序，轻扫删除；点击快捷键可以修改组合。", comment: "Watch 终端快捷键管理说明"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    LocalLinuxTerminalShortcutWatchEditorView(shortcut: nil) { shortcut in
                        selectedShortcuts.append(shortcut)
                        saveShortcuts()
                    }
                } label: {
                    Label(NSLocalizedString("添加快捷键", comment: "Watch 添加终端快捷键"), systemImage: "plus")
                }

                Button(NSLocalizedString("恢复默认", comment: "Watch 恢复默认终端快捷键")) {
                    selectedShortcuts = LocalLinuxTerminalShortcutConfiguration.defaults
                    saveShortcuts()
                }
            }
        }
        .navigationTitle(NSLocalizedString("终端快捷键", comment: "Watch 终端快捷键设置页标题"))
        .guideSettingsPageContext(
            id: "settings-local-linux-terminal-shortcuts",
            title: NSLocalizedString("终端快捷键", comment: "终端快捷键向导上下文标题"),
            documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux")],
            settings: [
                .json(
                    "shortcuts",
                    label: NSLocalizedString("终端快捷键列表", comment: "终端快捷键向导字段"),
                    schema: GuideLocalLinuxTerminalShortcutSettingsSupport.shortcutsSchema,
                    get: { GuideLocalLinuxTerminalShortcutSettingsSupport.value(selectedShortcuts) },
                    normalize: GuideLocalLinuxTerminalShortcutSettingsSupport.normalize,
                    set: { value in
                        selectedShortcuts = try GuideLocalLinuxTerminalShortcutSettingsSupport.shortcuts(from: value)
                        saveShortcuts()
                    }
                )
            ]
        )
        .watchGuideEntry()
        .onAppear(perform: reloadShortcuts)
        .onChange(of: appConfig.localLinuxTerminalShortcutIDs) { _, _ in
            reloadShortcuts()
        }
    }

    private var shortcutsBinding: Binding<[LocalLinuxTerminalShortcut]> {
        Binding(
            get: { selectedShortcuts },
            set: {
                selectedShortcuts = $0
                saveShortcuts()
            }
        )
    }

    private func replaceShortcut(id: UUID, with shortcut: LocalLinuxTerminalShortcut) {
        guard let index = selectedShortcuts.firstIndex(where: { $0.id == id }) else { return }
        selectedShortcuts[index] = shortcut
        saveShortcuts()
    }

    private func removeShortcut(id: UUID) {
        selectedShortcuts.removeAll { $0.id == id }
        saveShortcuts()
    }

    private func reloadShortcuts() {
        selectedShortcuts = LocalLinuxTerminalShortcutConfiguration.decode(appConfig.localLinuxTerminalShortcutIDs)
    }

    private func saveShortcuts() {
        appConfig.localLinuxTerminalShortcutIDs = LocalLinuxTerminalShortcutConfiguration.encode(selectedShortcuts)
    }
}

private struct LocalLinuxTerminalShortcutWatchEditorView: View {
    @Environment(\.dismiss) private var dismiss
    private let shortcutID: UUID
    private let isNewShortcut: Bool
    private let onSave: (LocalLinuxTerminalShortcut) -> Void
    @State private var selectedKeys: [LocalLinuxTerminalKey]

    private let columns = [GridItem(.adaptive(minimum: 38))]

    init(
        shortcut: LocalLinuxTerminalShortcut?,
        onSave: @escaping (LocalLinuxTerminalShortcut) -> Void
    ) {
        shortcutID = shortcut?.id ?? UUID()
        isNewShortcut = shortcut == nil
        self.onSave = onSave
        _selectedKeys = State(initialValue: shortcut?.keys ?? [])
    }

    var body: some View {
        List {
            Section(NSLocalizedString("快捷键组合", comment: "Watch 终端快捷键组合预览")) {
                Text(shortcut.title.isEmpty
                     ? NSLocalizedString("未选择按键", comment: "Watch 终端快捷键未选择按键")
                     : shortcut.title)
                    .foregroundStyle(shortcut.title.isEmpty ? Color.secondary : Color.primary)
            }

            keySection(
                title: NSLocalizedString("修饰键", comment: "Watch 终端快捷键修饰键分区"),
                keys: LocalLinuxTerminalKey.modifierKeys
            )
            keySection(
                title: NSLocalizedString("按键", comment: "Watch 终端快捷键普通按键分区"),
                keys: LocalLinuxTerminalKey.typingKeys
            )
            keySection(
                title: NSLocalizedString("导航键", comment: "Watch 终端快捷键导航键分区"),
                keys: LocalLinuxTerminalKey.navigationKeys
            )

            Section {
                Button(NSLocalizedString("保存", comment: "Watch 保存终端快捷键"), action: save)
                    .disabled(shortcut.inputData.isEmpty)
            }
        }
        .navigationTitle(NSLocalizedString(
            isNewShortcut ? "新增快捷键" : "编辑快捷键",
            comment: "Watch 终端快捷键编辑页标题"
        ))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "settings-local-linux-terminal-shortcut-\(shortcutID.uuidString.lowercased())"),
            title: NSLocalizedString(
                isNewShortcut ? "新增快捷键" : "编辑快捷键",
                comment: "终端快捷键编辑器向导上下文标题"
            ),
            documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux")],
            settings: [
                .json(
                    "keys",
                    label: NSLocalizedString("快捷键组合", comment: "终端快捷键编辑器向导字段"),
                    schema: GuideLocalLinuxTerminalShortcutSettingsSupport.keyListSchema,
                    get: { GuideLocalLinuxTerminalShortcutSettingsSupport.keyValue(selectedKeys) },
                    normalize: GuideLocalLinuxTerminalShortcutSettingsSupport.normalizeKeys,
                    set: { selectedKeys = try GuideLocalLinuxTerminalShortcutSettingsSupport.keys(from: $0) }
                ),
                .readOnly(
                    "requires_save",
                    label: NSLocalizedString("应用方式", comment: "向导设置字段"),
                    value: { .string(NSLocalizedString("修改后需要保存", comment: "向导草稿应用方式")) }
                )
            ]
        )
        .watchGuideEntry()
    }

    @ViewBuilder
    private func keySection(title: String, keys: [LocalLinuxTerminalKey]) -> some View {
        Section(title) {
            LazyVGrid(columns: columns) {
                ForEach(keys) { key in
                    keyButton(key)
                }
            }
        }
    }

    private func keyButton(_ key: LocalLinuxTerminalKey) -> some View {
        let isSelected = selectedKeys.contains(key)
        return Button {
            toggle(key)
        } label: {
            Text(key.title)
                .font(.caption2.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, minHeight: 28)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var shortcut: LocalLinuxTerminalShortcut {
        LocalLinuxTerminalShortcut(id: shortcutID, keys: selectedKeys)
    }

    private func toggle(_ key: LocalLinuxTerminalKey) {
        if let index = selectedKeys.firstIndex(of: key) {
            selectedKeys.remove(at: index)
        } else {
            selectedKeys.append(key)
        }
    }

    private func save() {
        onSave(shortcut)
        dismiss()
    }
}
