import ETOSCore
import SwiftUI

struct MacAnnouncementsView: View {
    let isActive: Bool
    @ObservedObject private var manager = AnnouncementManager.shared

    var body: some View {
        List {
            if manager.currentAnnouncements.isEmpty {
                Text(NSLocalizedString("暂无公告", value: "No announcements", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(manager.currentAnnouncements) { announcement in
                NavigationLink {
                    MacAnnouncementDetailView(isActive: isActive, announcement: announcement)
                } label: { Text(announcement.title) }
            }
        }
        .navigationTitle(NSLocalizedString("系统公告", comment: ""))
        .disabled(!isActive)
        .toolbar {
            Button(NSLocalizedString("刷新", comment: "")) { Task { await manager.checkAnnouncement() } }.disabled(manager.isLoading)
        }
        .guideSettingsPageContext(id: "mac-announcements", title: NSLocalizedString("系统公告", comment: ""),
            documents: [GuideDocumentReference(id: "mac-app-information", title: NSLocalizedString("系统公告", comment: ""))],
            isActive: isActive, settings: [.readOnly("count", label: NSLocalizedString("系统公告", comment: ""), value: { .int(manager.currentAnnouncements.count) })])
    }
}

private struct MacAnnouncementDetailView: View {
    let isActive: Bool
    let announcement: Announcement
    @Environment(\.dismiss) private var dismiss
    @State private var text: MacPreparedMessageText?
    var body: some View {
        Form {
            Section { if let text { MacMessageTextView(text: text) } }
            Section {
                Button(NSLocalizedString("不再显示", comment: "")) {
                    guard isActive else { return }
                    AnnouncementManager.shared.hideAnnouncement(announcement); dismiss()
                }
            }
        }
        .formStyle(.grouped).navigationTitle(announcement.title).disabled(!isActive)
        .task {
            let body = announcement.body
            let prepared = await Task.detached(priority: .utility) { MacPreparedMessageText(body, markdown: true) }.value
            if !Task.isCancelled { text = prepared }
        }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-announcement-\(announcement.id)"),
            title: NSLocalizedString("系统公告", comment: ""),
            documents: [GuideDocumentReference(id: "mac-app-information", title: NSLocalizedString("系统公告", comment: ""))],
            isActive: isActive, settings: [.readOnly("id", label: NSLocalizedString("系统公告", comment: ""), value: { .int(announcement.id) })])
    }
}
