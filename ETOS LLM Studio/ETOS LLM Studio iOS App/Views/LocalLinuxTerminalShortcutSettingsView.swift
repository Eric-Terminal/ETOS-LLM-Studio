// ============================================================================
// LocalLinuxTerminalShortcutSettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 端本地 Linux 终端快捷栏设置。
// ============================================================================

import ETOSCore
import SwiftUI

struct LocalLinuxTerminalShortcutSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var selectedShortcuts = LocalLinuxTerminalShortcutConfiguration.defaults

    var body: some View {
        List {
            Section {
                if selectedShortcuts.isEmpty {
                    Text(NSLocalizedString("还没有选择终端快捷键。", comment: "终端快捷键空状态"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shortcutsBinding, id: \.id, editActions: .move) { $shortcut in
                        NavigationLink {
                            LocalLinuxTerminalShortcutEditorView(shortcut: shortcut) { updated in
                                replaceShortcut(id: shortcut.id, with: updated)
                            }
                        } label: {
                            Text(shortcut.title)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                removeShortcut(id: shortcut.id)
                            } label: {
                                Label(NSLocalizedString("删除", comment: "删除终端快捷键"), systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("已显示的按键", comment: "终端快捷键已选择分区"))
            } footer: {
                Text(NSLocalizedString("长按拖动排序，轻扫删除；点击快捷键可以修改组合。", comment: "终端快捷键管理说明"))
            }

            Section {
                NavigationLink {
                    LocalLinuxTerminalShortcutEditorView(shortcut: nil) { shortcut in
                        selectedShortcuts.append(shortcut)
                        saveShortcuts()
                    }
                } label: {
                    Label(NSLocalizedString("添加快捷键", comment: "添加终端快捷键"), systemImage: "plus")
                }

                Button(NSLocalizedString("恢复默认", comment: "恢复默认终端快捷键")) {
                    selectedShortcuts = LocalLinuxTerminalShortcutConfiguration.defaults
                    saveShortcuts()
                }
            }
        }
        .navigationTitle(NSLocalizedString("终端快捷键", comment: "终端快捷键设置页标题"))
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

private struct LocalLinuxTerminalShortcutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    private let shortcutID: UUID
    private let isNewShortcut: Bool
    private let onSave: (LocalLinuxTerminalShortcut) -> Void
    @State private var selectedKeys: [LocalLinuxTerminalKey]

    private let columns = [GridItem(.adaptive(minimum: 56))]

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
        Form {
            Section(NSLocalizedString("快捷键组合", comment: "终端快捷键组合预览")) {
                LabeledContent(NSLocalizedString("发送内容", comment: "终端快捷键发送内容")) {
                    Text(shortcut.title.isEmpty
                         ? NSLocalizedString("未选择按键", comment: "终端快捷键未选择按键")
                         : shortcut.title)
                        .foregroundStyle(shortcut.title.isEmpty ? Color.secondary : Color.primary)
                }
            }

            keySection(
                title: NSLocalizedString("修饰键", comment: "终端快捷键修饰键分区"),
                keys: LocalLinuxTerminalKey.modifierKeys
            )
            keySection(
                title: NSLocalizedString("按键", comment: "终端快捷键普通按键分区"),
                keys: LocalLinuxTerminalKey.typingKeys
            )
            keySection(
                title: NSLocalizedString("导航键", comment: "终端快捷键导航键分区"),
                keys: LocalLinuxTerminalKey.navigationKeys
            )
        }
        .navigationTitle(NSLocalizedString(
            isNewShortcut ? "新增快捷键" : "编辑快捷键",
            comment: "终端快捷键编辑页标题"
        ))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "保存终端快捷键"), action: save)
                    .disabled(shortcut.inputData.isEmpty)
            }
        }
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
                .font(.body.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.accentColor : Color(uiColor: .secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
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
