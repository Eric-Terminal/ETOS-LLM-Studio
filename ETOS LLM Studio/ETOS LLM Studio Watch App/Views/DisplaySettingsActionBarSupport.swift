// ============================================================================
// DisplaySettingsActionBarSupport.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// watchOS 端气泡下方功能栏设置视图。
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct WatchMessageActionBarSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    let role: MessageActionBarRole

    private var configuration: MessageActionBarConfiguration {
        get { appConfig.messageActionBarSettings }
        nonmutating set { appConfig.messageActionBarSettings = newValue }
    }

    private var selectedItems: [MessageActionBarItem] {
        configuration.items(for: role)
    }

    private var availableItems: [MessageActionBarItem] {
        let selected = Set(selectedItems)
        return MessageActionBarItem.allCases.filter { item in
            !selected.contains(item) && item.isSupportedOnCurrentPlatform
        }
    }

    var body: some View {
        List {
            Section(
                footer: Text(NSLocalizedString("从上到下对应气泡下方的显示顺序。多版本切换移除后，仍可在长按菜单里管理版本。", comment: ""))
            ) {
                Picker(NSLocalizedString("延伸方向", comment: ""), selection: alignmentBinding) {
                    ForEach(MessageActionBarAlignment.allCases) { alignment in
                        Text(alignment.title).tag(alignment)
                    }
                }
            }

            Section(NSLocalizedString("已启用项目", comment: "")) {
                if selectedItems.isEmpty {
                    Text(NSLocalizedString("当前没有启用项目，可从下方添加。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(selectedItems.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 8) {
                            Label(item.title, systemImage: item.systemImage)
                            Spacer(minLength: 8)
                            HStack(spacing: 4) {
                                Button {
                                    moveItem(at: index, offset: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)

                                Button {
                                    moveItem(at: index, offset: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index >= selectedItems.count - 1)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                removeItem(item)
                            } label: {
                                Label(NSLocalizedString("移除", comment: ""), systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section(NSLocalizedString("可添加项目", comment: "")) {
                if availableItems.isEmpty {
                    Text(NSLocalizedString("所有项目都已加入。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(availableItems) { item in
                        Button {
                            addItem(item)
                        } label: {
                            Label(item.title, systemImage: item.systemImage)
                        }
                    }
                }
            }
        }
        .navigationTitle(role.title)
    }

    private var alignmentBinding: Binding<MessageActionBarAlignment> {
        Binding(
            get: { configuration.alignment(for: role) },
            set: { newValue in
                var updated = configuration
                updated.setAlignment(newValue, for: role)
                configuration = updated
            }
        )
    }

    private func addItem(_ item: MessageActionBarItem) {
        var updated = configuration
        var items = updated.items(for: role)
        guard !items.contains(item) else { return }
        items.append(item)
        updated.setItems(items, for: role)
        configuration = updated
    }

    private func removeItem(_ item: MessageActionBarItem) {
        var updated = configuration
        let items = updated.items(for: role).filter { $0 != item }
        updated.setItems(items, for: role)
        configuration = updated
    }

    private func moveItem(at index: Int, offset: Int) {
        var updated = configuration
        var items = updated.items(for: role)
        let destination = index + offset
        guard items.indices.contains(index), items.indices.contains(destination) else { return }
        items.swapAt(index, destination)
        updated.setItems(items, for: role)
        configuration = updated
    }
}

extension MessageActionBarRole {
    var title: String {
        switch self {
        case .assistant:
            return NSLocalizedString("助手气泡", comment: "")
        case .user:
            return NSLocalizedString("用户气泡", comment: "")
        }
    }
}

extension MessageActionBarAlignment {
    var title: String {
        switch self {
        case .leading:
            return NSLocalizedString("靠左延伸", comment: "")
        case .trailing:
            return NSLocalizedString("靠右延伸", comment: "")
        }
    }
}

extension MessageActionBarItem {
    var isSupportedOnCurrentPlatform: Bool {
        switch self {
        case .quickRetry, .copyMessage, .requestTime, .inputTokens, .outputTokens, .versionSwitcher:
            return true
        }
    }

    var title: String {
        switch self {
        case .quickRetry:
            return NSLocalizedString("快捷重试", comment: "")
        case .copyMessage:
            return NSLocalizedString("复制消息", comment: "")
        case .requestTime:
            return NSLocalizedString("请求时间", comment: "")
        case .inputTokens:
            return NSLocalizedString("输入 Token", comment: "")
        case .outputTokens:
            return NSLocalizedString("输出 Token", comment: "")
        case .versionSwitcher:
            return NSLocalizedString("多版本切换", comment: "")
        }
    }

    var systemImage: String {
        switch self {
        case .quickRetry:
            return "arrow.clockwise"
        case .copyMessage:
            return "doc.on.doc"
        case .requestTime:
            return "clock"
        case .inputTokens:
            return "arrow.up"
        case .outputTokens:
            return "arrow.down"
        case .versionSwitcher:
            return "arrow.left.arrow.right"
        }
    }
}
