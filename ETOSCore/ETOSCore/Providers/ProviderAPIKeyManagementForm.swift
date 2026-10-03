import SwiftUI

/// 每条凭据独立分组；密钥、备注和删除按钮各占一行，避免手表整行点击串联。
public struct ProviderAPIKeyManagementForm: View {
    @ObservedObject private var editor: ProviderAPIKeyEditorModel
    @State private var showsIntroDetails = false
    private let providerID: UUID
    private let textBinding: (Binding<String>) -> Binding<String>

    public init(
        editor: ProviderAPIKeyEditorModel,
        providerID: UUID,
        textBinding: @escaping (Binding<String>) -> Binding<String> = { $0 }
    ) {
        self.editor = editor
        self.providerID = providerID
        self.textBinding = textBinding
    }

    public var body: some View {
        Form {
            settingsIntroCard
            Section {
                Toggle(NSLocalizedString("显示全部 API Key", comment: ""), isOn: $editor.showsPlaintext)
            }
            ForEach($editor.draft.entries) { $entry in
                Section {
                    Group {
                        if editor.showsPlaintext {
                            TextField(NSLocalizedString("API Key", comment: ""), text: textBinding($entry.value))
                        } else {
                            SecureField(NSLocalizedString("API Key", comment: ""), text: textBinding($entry.value))
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    TextField(NSLocalizedString("备注（可选）", comment: ""), text: textBinding($entry.note))
                    Button(role: .destructive) {
                        editor.removeEntry(id: entry.id)
                    } label: {
                        Label(NSLocalizedString("删除 API Key", comment: ""), systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Section {
                Button { editor.addEntry() } label: {
                    Label(NSLocalizedString("添加 API Key", comment: ""), systemImage: "plus")
                }
            }
            Section {
                TextField(NSLocalizedString("最大换 Key 次数", comment: ""), text: textBinding($editor.draft.maximumRetriesText))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                if !editor.retryInputIsValid {
                    Text(NSLocalizedString("请输入 0 到 10 之间的整数。", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(NSLocalizedString("最大换 Key 次数", comment: ""))
            } footer: {
                Text(NSLocalizedString("首次请求不计入换 Key 次数。设为 0 仅关闭换 Key 重试，不影响全局自动重试。", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("管理 API Key", comment: ""))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "provider-api-keys-\(providerID)"),
            title: NSLocalizedString("管理 API Key", comment: ""),
            documents: [GuideDocumentReference(id: "provider-model-basics", title: "Provider and Model Basics")],
            settings: editor.guideSettings
        )
    }

    private var settingsIntroCard: some View {
        Section {
            DisclosureGroup(isExpanded: $showsIntroDetails) {
                Text(NSLocalizedString("按列表顺序轮换 API Key；聊天请求遇到可重试错误时，先尝试下一条 Key。可为每条 Key 添加备注，方便区分来源。", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("换 Key 次数与全局自动重试分别计数。换 Key 次数用完后，再按全局设置判断是否等待并重试；每轮自动重试都会重新计算换 Key 次数。关闭多 Key 模式后只使用第一条，其余 Key 和备注仍会保留。", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("此页修改先保留为草稿，返回提供商页面后点击保存生效。", comment: ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } label: {
                Label(NSLocalizedString("多 Key 模式", comment: ""), systemImage: "key.horizontal")
            }
        }
    }
}
