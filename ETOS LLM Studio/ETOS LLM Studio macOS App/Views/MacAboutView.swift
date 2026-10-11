import AppKit
import ETOSCore
import SwiftUI

struct MacAboutView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var model = MacAppInformationModel.shared
    @State private var version = ""
    @State private var commit = ""
    @State private var taps = 0
    @State private var lastTap = Date.distantPast
    private var available: Bool { isActive && workspace.canManageLocalModels }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "about", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 应用信息使用说明", value: "Check the update timeline, read announcements, and browse local logs here. Official data synchronization first shows a preview; review it and confirm before applying changes. Existing credentials and local model activation choices are preserved. The page guide cannot start synchronization or read log and feedback contents.", comment: ""),
                    documentID: "mac-app-information", isActive: available)
            }
            Section(NSLocalizedString("应用信息", comment: "")) {
                LabeledContent(NSLocalizedString("版本", comment: ""), value: version)
                    .contentShape(Rectangle()).onTapGesture {
                        let now = Date()
                        taps = now.timeIntervalSince(lastTap) < 2 ? taps + 1 : 1
                        lastTap = now
                        if taps == 7 { Task { await AchievementCenter.shared.unlock(id: .forbiddenPlace) } }
                    }
                LabeledContent(NSLocalizedString("Git 提交", comment: ""), value: commit)
                LabeledContent(NSLocalizedString("开发者", comment: ""), value: NSLocalizedString("Eric-Terminal", comment: ""))
                NavigationLink(NSLocalizedString("检查更新", comment: "")) { MacUpdateTimelineView(isActive: available) }
                NavigationLink(NSLocalizedString("系统公告", comment: "")) { MacAnnouncementsView(isActive: available) }
                NavigationLink(NSLocalizedString("应用日志", comment: "")) { MacAppLogsView(isActive: available) }
            }
            Section(NSLocalizedString("软件服务", comment: "")) {
                Button(NSLocalizedString("同步官方数据", comment: "")) { model.prepareOfficialData() }
                    .disabled(model.working || model.updates == nil)
                if model.working { ProgressView() }
                if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }
            Section(NSLocalizedString("官方社群", comment: "")) {
                Link(NSLocalizedString("Telegram 社群", comment: ""), destination: URL(string: "https://t.me/ETOSLLMStudio")!)
                Button(NSLocalizedString("QQ 群", comment: "") + " · 974605250") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("974605250", forType: .string)
                }.help(NSLocalizedString("复制", comment: ""))
            }
            Section(NSLocalizedString("链接", comment: "")) {
                Link(NSLocalizedString("GitHub 项目主页", comment: ""), destination: URL(string: "https://github.com/Eric-Terminal/ETOS-LLM-Studio")!)
                Button(NSLocalizedString("文档", comment: "")) { open("https://docs.els.ericterminal.com/", achievement: .documentationReader) }
                Button(NSLocalizedString("隐私政策", comment: "")) { open("https://privacy.els.ericterminal.com/", achievement: .privacyReader) }
                LabeledContent(NSLocalizedString("开源协议", comment: ""), value: NSLocalizedString("GPLv3", comment: ""))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("关于 ETOS LLM Studio", comment: ""))
        .disabled(!available)
        .task {
            let metadata = await Task.detached(priority: .utility) {
                let info = Bundle.main.infoDictionary ?? [:]
                return ("\(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))",
                        String((info["ETCommitHash"] as? String ?? "").prefix(12)))
            }.value
            version = metadata.0; commit = metadata.1
        }
        .sheet(item: $model.preview) { preview in
            MacOfficialDataPreviewView(preview: preview, isActive: available)
        }
        .guideSettingsPageContext(id: "mac-about", title: NSLocalizedString("关于 ETOS LLM Studio", comment: ""),
            documents: [GuideDocumentReference(id: "mac-app-information", title: NSLocalizedString("关于 ETOS LLM Studio", comment: ""))],
            isActive: available && model.preview == nil, settings: [
                .readOnly("version", label: NSLocalizedString("版本", comment: ""), value: { .string(version) }),
                .readOnly("commit", label: NSLocalizedString("Git 提交", comment: ""), value: { .string(commit) }),
                .readOnly("working", label: NSLocalizedString("同步官方数据", comment: ""), value: { .bool(model.working) })
            ])
    }

    private func open(_ address: String, achievement: AchievementID) {
        guard let url = URL(string: address), NSWorkspace.shared.open(url) else { return }
        Task { await AchievementCenter.shared.unlock(id: achievement) }
    }
}

struct MacAppInformationHost: ViewModifier {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    func body(content: Content) -> some View {
        content.task(id: workspace.canManageLocalModels) {
            if workspace.canManageLocalModels { MacAppInformationModel.shared.activate() }
            else { await MacAppInformationModel.shared.suspend() }
        }
    }
}
