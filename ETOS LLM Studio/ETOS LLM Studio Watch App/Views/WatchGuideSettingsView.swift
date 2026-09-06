// ============================================================================
// WatchGuideSettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 与 iOS 共用页面向导的能力和数据边界，只采用适合手表的列表与二级导航。
// ============================================================================

import SwiftUI
import ETOSCore

struct WatchGuideSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared

    var body: some View {
        List {
            Section {
                Label(NSLocalizedString("向导会看到什么", comment: "向导介绍标题"), systemImage: "eye")

                Text(NSLocalizedString("当前页面会明确提供页面名称、相关文档和经过筛选的配置快照。密钥、密码与令牌只显示为已隐藏。", comment: "向导介绍摘要"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    WatchGuidePrivacyView()
                } label: {
                    Text(NSLocalizedString("进一步了解…", comment: "向导隐私详情入口"))
                }
            }

            Section {
                Toggle(
                    NSLocalizedString("在设置页面显示向导", comment: "手表向导入口开关"),
                    isOn: $appConfig.guideOverlayEnabled
                )
            } footer: {
                Text(NSLocalizedString("开启后，已接入的设置页面会在顶部显示向导入口；点击后进入二级对话页面。", comment: "手表向导入口说明"))
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
        .watchGuideEntry()
    }
}

private struct WatchGuidePrivacyView: View {
    var body: some View {
        ScrollView {
            Text(NSLocalizedString("guide.privacy.details", value: "Open the guide on a settings page to ask what an option does or describe the setup you want. It uses information and documentation provided by the page, and can consult the public source code for your app version when needed.\n\nSupported changes are previewed and applied only after you confirm. Editor drafts still need to be saved as indicated on the page. Existing keys, passwords and tokens are not sent to the guide model; enter new secrets in the app’s secure input fields.\n\nPage help and first-model setup each keep their last conversation on this device so you can continue after reopening the app. Clearing context also deletes the saved conversation. These records are not added to your main chats or device sync. Tool records keep only names and statuses. Pending changes, undo records and secret drafts are not restored after a restart.", comment: "向导隐私详情"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(NSLocalizedString("页面向导与隐私", comment: "向导隐私详情标题"))
    }
}
