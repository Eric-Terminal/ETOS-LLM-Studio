// ============================================================================
// GuideSettingsView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 集中说明页面向导的数据边界，并配置浮动入口。
// ============================================================================

import SwiftUI
import ETOSCore

struct GuideSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var isShowingDetails = false

    var body: some View {
        Form {
            Section {
                introductionCard
            }

            Section {
                Toggle(
                    NSLocalizedString("在设置页面显示向导", comment: "向导浮动入口开关"),
                    isOn: $appConfig.guideOverlayEnabled
                )
            } footer: {
                Text(NSLocalizedString("开启后，进入设置及已接入的配置页面时会显示可拖动的向导入口。", comment: "向导浮动入口说明"))
            }
        }
        .navigationTitle(NSLocalizedString("页面向导", comment: "向导设置标题"))
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: "guide-settings",
                title: NSLocalizedString("页面向导设置", comment: "向导设置页面上下文标题"),
                documents: [GuideDocumentReference(id: "guide-overview", title: "Guide Overview")]
            ),
            snapshot: {
                GuidePageSnapshot(fields: [
                    "overlay_enabled": GuideSnapshotField(
                        label: NSLocalizedString("显示向导", comment: "向导快照字段"),
                        value: .bool(appConfig.guideOverlayEnabled)
                    )
                ])
            }
        )
    }

    private var introductionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(NSLocalizedString("向导会看到什么", comment: "向导介绍卡标题"), systemImage: "eye")
                .font(.headline)
            Text(NSLocalizedString("当前页面会明确提供页面名称、相关文档和经过筛选的配置快照。密钥、密码与令牌只显示为已隐藏。", comment: "向导介绍卡摘要"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(NSLocalizedString("进一步了解…", comment: "向导介绍卡详情按钮")) {
                isShowingDetails = true
            }
            .buttonStyle(.plain)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isShowingDetails) {
            NavigationStack {
                ScrollView {
                    Text(NSLocalizedString("guide.privacy.details", value: "Open the guide on a settings page to ask what an option does or describe the setup you want. It uses information and documentation provided by the page, and can consult the public source code for your app version when needed.\n\nSupported changes are previewed and applied only after you confirm. Editor drafts still need to be saved as indicated on the page. Existing keys, passwords and tokens are not sent to the guide model; enter new secrets in the app’s secure input fields.\n\nPage help and first-model setup each keep their last conversation on this device so you can continue after reopening the app. Clearing context also deletes the saved conversation. These records are not added to your main chats or device sync. Tool records keep only names and statuses. Pending changes, undo records and secret drafts are not restored after a restart.", comment: "向导介绍卡详情"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString("页面向导与隐私", comment: "向导介绍详情标题"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
