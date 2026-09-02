// ============================================================================
// SlashCommandSettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件提供 watchOS 快速指令的开关、内建命令速查与自定义提示词命令管理。
// ============================================================================

import SwiftUI
import ETOSCore

struct SlashCommandSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var customCommandStore = CustomChatSlashCommandStore.shared

    var body: some View {
        List {
            Section {
                Toggle(
                    NSLocalizedString("启用快速指令", comment: "Enable quick commands toggle"),
                    isOn: $appConfig.enableSlashCommands
                )
            } footer: {
                Text(NSLocalizedString("默认关闭。启用后，提交以 / 开头的输入即可显示命令；内建命令会直接执行，自定义命令会将提示词填入输入框。", comment: "Watch slash commands setting footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    WatchCustomSlashCommandEditorView(command: nil)
                } label: {
                    Label(
                        NSLocalizedString("添加快速指令", comment: "Add custom slash command button"),
                        systemImage: "plus"
                    )
                }

                ForEach(customCommandStore.commands) { command in
                    NavigationLink {
                        WatchCustomSlashCommandEditorView(command: command)
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(command.invocation)
                                    .etFont(.footnote.monospaced())
                                Text(command.prompt)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        } icon: {
                            Image(systemName: "text.bubble")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .onDelete(perform: deleteCustomCommands)
            } header: {
                Text(NSLocalizedString("自定义命令", comment: "Custom slash commands section"))
            } footer: {
                Text(NSLocalizedString("自定义命令会把提示词填入聊天输入框，不会自动发送。", comment: "Custom slash commands section footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(ChatSlashCommand.allCases) { command in
                    Label {
                        VStack(alignment: .leading) {
                            Text(command.invocation)
                                .etFont(.body.monospaced())
                            Text(NSLocalizedString(command.titleLocalizationKey, comment: "Slash command description"))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: command.systemImage)
                            .foregroundStyle(.tint)
                    }
                }
            } header: {
                Text(NSLocalizedString("可用命令", comment: "Available slash commands section"))
            }
        }
        .navigationTitle(NSLocalizedString("快速指令", comment: "Quick command settings title"))
        .guideSettingsPageContext(
            id: "watch-settings-slash-commands",
            title: NSLocalizedString("快速指令", comment: "快速指令向导标题"),
            documents: [GuideDocumentReference(id: "slash-commands", title: "Quick Commands")],
            settings: guideSettings
        )
        .watchGuideEntry()
    }

    private var guideSettings: [GuidePageSetting] {
        [
            .bool("enabled", label: NSLocalizedString("启用快速指令", comment: "快速指令向导字段"), get: { appConfig.enableSlashCommands }, set: { appConfig.enableSlashCommands = $0 }),
            .json(
                "custom_commands",
                label: NSLocalizedString("自定义快速指令列表", comment: "快速指令向导字段"),
                schema: GuideSlashCommandSettingsSupport.schema,
                get: { GuideSlashCommandSettingsSupport.value(customCommandStore.commands) },
                normalize: GuideSlashCommandSettingsSupport.normalize,
                set: { try GuideSlashCommandSettingsSupport.apply($0, to: customCommandStore) }
            ),
            .readOnly("built_in_commands", label: NSLocalizedString("内建快速指令", comment: "快速指令向导字段"), value: {
                .array(ChatSlashCommand.allCases.map { .string($0.invocation) })
            })
        ]
    }

    private func deleteCustomCommands(at offsets: IndexSet) {
        let commandIDs = offsets.map { customCommandStore.commands[$0].id }
        commandIDs.forEach { customCommandStore.delete(id: $0) }
    }
}

private struct WatchCustomSlashCommandEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CustomChatSlashCommandStore.shared

    let command: CustomChatSlashCommand?
    @State private var trigger: String
    @State private var prompt: String

    init(command: CustomChatSlashCommand?) {
        self.command = command
        _trigger = State(initialValue: command?.trigger ?? "")
        _prompt = State(initialValue: command?.prompt ?? "")
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("/")
                        .foregroundStyle(.secondary)
                    TextField(
                        NSLocalizedString("例如：sk", comment: "Custom slash command trigger example"),
                        text: $trigger
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
            } header: {
                Text(NSLocalizedString("激活指令", comment: "Custom slash command trigger section"))
            } footer: {
                if let triggerValidationMessage {
                    Text(triggerValidationMessage)
                        .foregroundStyle(.red)
                } else {
                    Text(NSLocalizedString("输入 / 后使用此名称查找命令。可使用字母、数字、短横线和下划线。", comment: "Custom slash command trigger help"))
                }
            }

            Section {
                TextField(
                    NSLocalizedString("输入发送给 AI 的提示词", comment: "Custom slash command prompt placeholder"),
                    text: $prompt.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                .lineLimit(4...8)
            } header: {
                Text(NSLocalizedString("提示词", comment: "Custom slash command prompt section"))
            } footer: {
                Text(NSLocalizedString("选择命令后，提示词会先填入输入框，确认后再发送。", comment: "Custom slash command prompt help"))
            }

            Section {
                Button(NSLocalizedString("保存", comment: ""), action: save)
                    .disabled(!canSave)
            }
        }
        .navigationTitle(
            command == nil
                ? NSLocalizedString("新增快速指令", comment: "Add custom slash command title")
                : NSLocalizedString("编辑快速指令", comment: "Edit custom slash command title")
        )
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "watch-slash-command-editor-\(command?.id.uuidString.lowercased() ?? "new")"),
            title: command == nil
                ? NSLocalizedString("新增快速指令", comment: "快速指令编辑器向导标题")
                : NSLocalizedString("编辑快速指令", comment: "快速指令编辑器向导标题"),
            documents: [GuideDocumentReference(id: "slash-commands", title: "Quick Commands")],
            settings: editorGuideSettings
        )
        .watchGuideEntry()
    }

    private var editorGuideSettings: [GuidePageSetting] {
        [
            .readOnly("editor_mode", label: NSLocalizedString("编辑模式", comment: "快速指令编辑器向导字段"), value: {
                .string(command == nil ? "create" : "edit")
            }),
            .json(
                "trigger",
                label: NSLocalizedString("激活指令", comment: "快速指令编辑器向导字段"),
                schema: .dictionary(["type": .string("string")]),
                get: { .string(trigger) },
                normalize: { value in
                    guard case .string(let rawValue) = value else { throw GuideError.invalidToolArguments }
                    let canonical = CustomChatSlashCommandStore.canonicalTrigger(rawValue)
                    guard CustomChatSlashCommandStore.isValidTrigger(canonical),
                          !ChatSlashCommandParser.isReservedTrigger(canonical),
                          store.isTriggerAvailable(canonical, excluding: command?.id) else {
                        throw GuideError.invalidToolArguments
                    }
                    return .string(canonical)
                },
                set: { value in
                    guard case .string(let resolved) = value else { throw GuideError.invalidToolArguments }
                    trigger = resolved
                }
            ),
            .string("prompt", label: NSLocalizedString("提示词", comment: "快速指令编辑器向导字段"), allowsEmpty: false, get: { prompt }, set: { prompt = $0 })
        ]
    }

    private var canonicalTrigger: String {
        CustomChatSlashCommandStore.canonicalTrigger(trigger)
    }

    private var triggerValidationMessage: String? {
        guard !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard CustomChatSlashCommandStore.isValidTrigger(trigger) else {
            return NSLocalizedString("指令只能包含字母、数字、短横线和下划线。", comment: "Invalid custom slash command trigger")
        }
        guard !ChatSlashCommandParser.isReservedTrigger(trigger) else {
            return NSLocalizedString("该指令与内建命令重复。", comment: "Reserved custom slash command trigger")
        }
        guard store.isTriggerAvailable(trigger, excluding: command?.id) else {
            return NSLocalizedString("已有同名的自定义指令。", comment: "Duplicate custom slash command trigger")
        }
        return nil
    }

    private var canSave: Bool {
        !canonicalTrigger.isEmpty
            && triggerValidationMessage == nil
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        store.upsert(CustomChatSlashCommand(
            id: command?.id ?? UUID(),
            trigger: canonicalTrigger,
            prompt: prompt,
            updatedAt: Date()
        ))
        dismiss()
    }
}
