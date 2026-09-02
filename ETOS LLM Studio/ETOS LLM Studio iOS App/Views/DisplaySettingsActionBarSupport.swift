// ============================================================================
// DisplaySettingsActionBarSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 端气泡下方功能栏设置视图。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct MessageActionBarSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var selectedRole: MessageActionBarRole = .assistant

    private var configuration: MessageActionBarConfiguration {
        get { appConfig.messageActionBarSettings }
        nonmutating set { appConfig.messageActionBarSettings = newValue }
    }

    private var selectedItems: [MessageActionBarItem] {
        configuration.items(for: selectedRole)
    }

    private var availableItems: [MessageActionBarItem] {
        let selected = Set(selectedItems)
        return MessageActionBarItem.supportedItems(for: selectedRole).filter { !selected.contains($0) }
    }

    var body: some View {
        Form {
            roleSection
            layoutSection
            fontScaleSection
            enabledItemsSection
            availableItemsSection
        }
        .navigationTitle(NSLocalizedString("功能栏自定义", comment: ""))
        .guideSettingsPageContext(
            id: "settings-message-action-bar",
            title: NSLocalizedString("功能栏自定义", comment: "消息功能栏向导上下文标题"),
            documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")],
            settings: actionBarGuideSettings
        )
        .toolbar {
            EditButton()
        }
    }

    private var actionBarGuideSettings: [GuidePageSetting] {
        [
            .string("message_role", label: NSLocalizedString("消息类型", comment: "消息功能栏向导字段"), allowedValues: MessageActionBarRole.allCases.map(\.rawValue), get: { selectedRole.rawValue }, set: { selectedRole = MessageActionBarRole(rawValue: $0) ?? selectedRole }),
            .string("alignment", label: NSLocalizedString("功能栏位置", comment: "消息功能栏向导字段"), allowedValues: MessageActionBarAlignment.allCases.map(\.rawValue), get: { alignmentBinding.wrappedValue.rawValue }, set: { alignmentBinding.wrappedValue = MessageActionBarAlignment(rawValue: $0) ?? alignmentBinding.wrappedValue }),
            .bool("outer_border", label: NSLocalizedString("显示外围边框", comment: "消息功能栏向导字段"), get: { outerBorderBinding.wrappedValue }, set: { outerBorderBinding.wrappedValue = $0 }),
            .double("font_scale", label: NSLocalizedString("字号比例", comment: "消息功能栏向导字段"), range: FontLibrary.minimumFontScale...FontLibrary.maximumFontScale, get: { fontScaleBinding.wrappedValue }, set: { fontScaleBinding.wrappedValue = $0 }),
            .json(
                "items",
                label: NSLocalizedString("已启用项目", comment: "消息功能栏向导字段"),
                schema: GuideDisplayActionSettingsSupport.messageActionItemsSchema,
                get: { GuideDisplayActionSettingsSupport.messageActionItemsValue(selectedItems) },
                normalize: GuideDisplayActionSettingsSupport.normalizeMessageActionItems,
                set: { value in
                    let items = try GuideDisplayActionSettingsSupport.messageActionItems(from: value)
                    let supported = Set(MessageActionBarItem.supportedItems(for: selectedRole))
                    guard items.allSatisfy(supported.contains) else { throw GuideError.invalidToolArguments }
                    var updated = configuration
                    updated.setItems(items, for: selectedRole)
                    configuration = updated
                }
            )
        ]
    }

    private var roleSection: some View {
        Section {
            Picker(NSLocalizedString("消息类型", comment: ""), selection: $selectedRole) {
                ForEach(MessageActionBarRole.allCases) { role in
                    Text(role.title).tag(role)
                }
            }
        } footer: {
            Text(NSLocalizedString("助手气泡和用户气泡可以分别配置。列表从上到下对应气泡下方从左到右或从右到左的显示顺序。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var layoutSection: some View {
        Section(NSLocalizedString("显示方式", comment: "")) {
            Picker(NSLocalizedString("功能栏位置", comment: ""), selection: alignmentBinding) {
                ForEach(MessageActionBarAlignment.allCases) { alignment in
                    Text(alignment.title).tag(alignment)
                }
            }

            Toggle(NSLocalizedString("显示外围边框", comment: ""), isOn: outerBorderBinding)
        }
    }

    private var fontScaleSection: some View {
        Section {
            VStack(alignment: .leading) {
                HStack {
                    Text(NSLocalizedString("字号比例", comment: ""))
                    Spacer()
                    Text("\(Int((fontScaleBinding.wrappedValue * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: fontScaleBinding,
                    in: FontLibrary.minimumFontScale...FontLibrary.maximumFontScale,
                    step: FontLibrary.fontScaleStep
                )
            }

            Button(NSLocalizedString("恢复默认字号", comment: "")) {
                fontScaleBinding.wrappedValue = FontLibrary.defaultFontScale
            }
            .disabled(abs(fontScaleBinding.wrappedValue - FontLibrary.defaultFontScale) < 0.001)
        } header: {
            Text(NSLocalizedString("字体大小", comment: ""))
        } footer: {
            Text(NSLocalizedString("在全局字号比例的基础上，单独调整气泡功能栏的文字和图标大小。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var enabledItemsSection: some View {
        Section {
            if selectedItems.isEmpty {
                Text(NSLocalizedString("当前没有启用项目，可从下方添加。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(selectedItems) { item in
                    itemRow(item)
                }
                .onMove(perform: moveSelectedItems)
                .onDelete(perform: removeSelectedItems)
            }
        } header: {
            Text(NSLocalizedString("已启用项目", comment: ""))
        } footer: {
            Text(NSLocalizedString("点击右上角“编辑”后，可拖拽右侧把手调整顺序；右滑可移除。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var availableItemsSection: some View {
        Section(NSLocalizedString("可添加项目", comment: "")) {
            if availableItems.isEmpty {
                Text(NSLocalizedString("所有项目都已加入。", comment: ""))
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

    private var alignmentBinding: Binding<MessageActionBarAlignment> {
        Binding(
            get: { configuration.alignment(for: selectedRole) },
            set: { newValue in
                var updated = configuration
                updated.setAlignment(newValue, for: selectedRole)
                configuration = updated
            }
        )
    }

    private var outerBorderBinding: Binding<Bool> {
        Binding(
            get: { configuration.showsOuterBorder },
            set: { newValue in
                var updated = configuration
                updated.showsOuterBorder = newValue
                configuration = updated
            }
        )
    }

    private var fontScaleBinding: Binding<Double> {
        Binding(
            get: { configuration.fontScale },
            set: { newValue in
                var updated = configuration
                updated.fontScale = FontLibrary.normalizedFontScale(newValue)
                configuration = updated
            }
        )
    }

    private func itemRow(_ item: MessageActionBarItem) -> some View {
        Label {
            Text(item.title)
        } icon: {
            Image(systemName: item.systemImage)
                .foregroundStyle(item.tint)
        }
    }

    private func addItem(_ item: MessageActionBarItem) {
        var updated = configuration
        var items = updated.items(for: selectedRole)
        guard !items.contains(item) else { return }
        items.append(item)
        updated.setItems(items, for: selectedRole)
        configuration = updated
    }

    private func moveSelectedItems(from source: IndexSet, to destination: Int) {
        var updated = configuration
        var items = updated.items(for: selectedRole)
        items.move(fromOffsets: source, toOffset: destination)
        updated.setItems(items, for: selectedRole)
        configuration = updated
    }

    private func removeSelectedItems(at offsets: IndexSet) {
        var updated = configuration
        var items = updated.items(for: selectedRole)
        items.remove(atOffsets: offsets)
        updated.setItems(items, for: selectedRole)
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
        case .costEstimate:
            return NSLocalizedString("费用", comment: "Message action bar cost item title")
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
        case .costEstimate:
            return "dollarsign.circle"
        case .versionSwitcher:
            return "arrow.left.arrow.right"
        }
    }

    var tint: Color {
        switch self {
        case .quickRetry:
            return .orange
        case .copyMessage:
            return .blue
        case .requestTime:
            return .secondary
        case .inputTokens:
            return .green
        case .outputTokens:
            return .purple
        case .costEstimate:
            return .yellow
        case .versionSwitcher:
            return .indigo
        }
    }
}
