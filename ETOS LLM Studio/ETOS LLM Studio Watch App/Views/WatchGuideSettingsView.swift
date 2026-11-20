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
                Label(NSLocalizedString("使用助手能帮我做什么", value: "How App Guide Helps", comment: "向导介绍标题"), systemImage: "sparkles")

                Text(NSLocalizedString("guide.help.summary", value: "Ask where to find a feature or what an option on this page does. The guide can change settings after you confirm. Your saved passwords and API keys stay hidden.", comment: "向导介绍摘要"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    WatchGuidePrivacyView()
                } label: {
                    Text(NSLocalizedString("进一步了解…", value: "How to use", comment: "向导隐私详情入口"))
                }
            }

            Section {
                Toggle(
                    NSLocalizedString("在设置页面显示使用助手", value: "Show App Guide in Settings", comment: "手表向导入口开关"),
                    isOn: $appConfig.guideOverlayEnabled
                )
            } footer: {
                Text(NSLocalizedString("watch.guide.entry.footer", value: "Tap the ellipsis at the top of a supported settings page, then choose Open App Guide.", comment: "手表向导入口说明"))
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
        .watchGuideEntry()
    }
}

private struct WatchGuidePrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                Text(NSLocalizedString("watch.guide.usage.details", value: "Open a settings page, tap the ellipsis at the top, then choose Open App Guide. The same menu contains page actions such as Save and Add; these remain available when the guide is turned off. Enter your question at the top of the guide window, then tap Send.\n\nTap the current answer model to choose another one. The model picker follows your main model picker’s provider grouping and folders. The built-in guide remains available at the top. Choosing a model returns to the conversation.\n\nThe guide keeps the original settings page as its context while you choose a model, edit a message or review a proposed change. Close the guide to return to that page.", comment: "手表向导操作教程"))
                Text(NSLocalizedString("guide.privacy.details", value: "Open the guide on a settings page to ask what an option does or describe the setup you want. It uses information and documentation provided by the page, and can consult the public source code for your app version when needed.\n\nSupported changes are previewed and applied only after you confirm. Editor drafts still need to be saved as indicated on the page. Existing keys, passwords and tokens are not sent to the guide model; enter new secrets in the app’s secure input fields.\n\nPage help and first-model setup each keep their last conversation on this device so you can continue after reopening the app. Clearing context also deletes the saved conversation. These records are not added to your main chats or device sync. Tool records keep only names and statuses. Pending changes, undo records and secret drafts are not restored after a restart.", comment: "向导隐私详情"))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(NSLocalizedString("使用助手与隐私", value: "App Guide and Privacy", comment: "向导隐私详情标题"))
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: "guide-privacy",
                title: NSLocalizedString("使用助手与隐私", value: "App Guide and Privacy", comment: "向导隐私详情上下文标题"),
                documents: [GuideDocumentReference(id: "guide-overview", title: "Guide Overview")]
            ),
            snapshot: { .empty }
        )
        .watchGuideEntry()
    }
}
