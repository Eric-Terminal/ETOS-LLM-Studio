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
                    NSLocalizedString("在设置页面显示使用助手", value: "Show App Guide in Settings", comment: "向导浮动入口开关"),
                    isOn: $appConfig.guideOverlayEnabled
                )
            } footer: {
                Text(NSLocalizedString("开启后，进入设置及已接入的配置页面时会显示可拖动的向导入口。", value: "When enabled, a draggable guide button appears on Settings and supported configuration pages.", comment: "向导浮动入口说明"))
            }
        }
        .navigationTitle(NSLocalizedString("使用助手", value: "App Guide", comment: "向导设置标题"))
        .guideSettingsPageContext(
            id: "guide-settings",
            title: NSLocalizedString("使用助手设置", value: "App Guide Settings", comment: "助手设置页标题"),
            documents: [GuideDocumentReference(id: "guide-overview", title: "Guide Overview")],
            settings: [.bool("overlay_enabled", label: NSLocalizedString("在设置页面显示使用助手", value: "Show App Guide in Settings", comment: "设置助手入口开关"),
                             get: { appConfig.guideOverlayEnabled }, set: { appConfig.guideOverlayEnabled = $0 })]
        )
    }

    private var introductionCard: some View {
        VStack(alignment: .leading) {
            Label(NSLocalizedString("使用助手能帮我做什么", value: "How App Guide Helps", comment: "向导介绍卡标题"), systemImage: "sparkles")
                .font(.headline)
            Text(NSLocalizedString("guide.help.summary", value: "Ask where to find a feature or what an option on this page does. The guide can change settings after you confirm. Your saved passwords and API keys stay hidden.", comment: "向导介绍卡摘要"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(NSLocalizedString("进一步了解…", value: "How to use", comment: "向导介绍卡详情按钮")) {
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
                .navigationTitle(NSLocalizedString("使用助手与隐私", value: "App Guide and Privacy", comment: "向导介绍详情标题"))
                .navigationBarTitleDisplayMode(.inline)
                .guidePageContext(descriptor: GuidePageDescriptor(id: "guide-privacy", title: NSLocalizedString("使用助手与隐私", value: "App Guide and Privacy", comment: "助手隐私说明"),
                    documents: [GuideDocumentReference(id: "guide-overview", title: "Guide Overview")]), snapshot: { .empty })
            }
        }
    }
}
