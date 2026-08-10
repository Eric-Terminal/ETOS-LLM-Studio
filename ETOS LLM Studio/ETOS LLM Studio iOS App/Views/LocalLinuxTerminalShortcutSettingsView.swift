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
    @State private var availableShortcuts: [LocalLinuxTerminalShortcut] = []

    var body: some View {
        List {
            Section {
                if selectedShortcuts.isEmpty {
                    Text(NSLocalizedString("还没有选择终端快捷键。", comment: "终端快捷键空状态"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(selectedShortcuts) { shortcut in
                        Text(shortcut.title)
                    }
                    .onDelete(perform: removeShortcuts)
                    .onMove(perform: moveShortcuts)
                }
            } header: {
                Text(NSLocalizedString("已显示的按键", comment: "终端快捷键已选择分区"))
            } footer: {
                Text(NSLocalizedString("终端会按照这里的顺序横向显示；拖动可排序，轻扫可移除。", comment: "终端快捷键排序说明"))
            }

            if !availableShortcuts.isEmpty {
                Section(NSLocalizedString("添加按键", comment: "终端快捷键可添加分区")) {
                    ForEach(availableShortcuts) { shortcut in
                        Button {
                            addShortcut(shortcut)
                        } label: {
                            HStack {
                                Text(shortcut.title)
                                Spacer()
                                Image(systemName: "plus")
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section {
                Button(NSLocalizedString("恢复默认", comment: "恢复默认终端快捷键")) {
                    selectedShortcuts = LocalLinuxTerminalShortcutConfiguration.defaults
                    saveShortcuts()
                }
            }
        }
        .navigationTitle(NSLocalizedString("终端快捷键", comment: "终端快捷键设置页标题"))
        .toolbar { EditButton() }
        .onAppear(perform: reloadShortcuts)
        .onChange(of: appConfig.localLinuxTerminalShortcutIDs) { _, _ in
            reloadShortcuts()
        }
    }

    private func addShortcut(_ shortcut: LocalLinuxTerminalShortcut) {
        selectedShortcuts.append(shortcut)
        saveShortcuts()
    }

    private func removeShortcuts(at offsets: IndexSet) {
        selectedShortcuts.remove(atOffsets: offsets)
        saveShortcuts()
    }

    private func moveShortcuts(from source: IndexSet, to destination: Int) {
        selectedShortcuts.move(fromOffsets: source, toOffset: destination)
        saveShortcuts()
    }

    private func reloadShortcuts() {
        selectedShortcuts = LocalLinuxTerminalShortcutConfiguration.decode(appConfig.localLinuxTerminalShortcutIDs)
        refreshAvailableShortcuts()
    }

    private func saveShortcuts() {
        refreshAvailableShortcuts()
        appConfig.localLinuxTerminalShortcutIDs = LocalLinuxTerminalShortcutConfiguration.encode(selectedShortcuts)
    }

    private func refreshAvailableShortcuts() {
        let selected = Set(selectedShortcuts)
        availableShortcuts = LocalLinuxTerminalShortcut.allCases.filter { !selected.contains($0) }
    }
}
