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
            ForEach(manager.currentAnnouncements, id: \.uniqueKey) { announcement in
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
            documents: [GuideDocumentReference(id: "announcement-translation", title: NSLocalizedString("系统公告", comment: ""))],
            isActive: isActive, settings: [.readOnly("count", label: NSLocalizedString("系统公告", comment: ""), value: { .int(manager.currentAnnouncements.count) })])
    }
}

private struct MacAnnouncementDetailView: View {
    let isActive: Bool
    let announcement: Announcement
    @Environment(\.dismiss) private var dismiss
    @StateObject private var translation = AnnouncementTranslationModel()

    var body: some View {
        Form {
            Section {
                AnnouncementTranslationButton(translation)
                MacAnnouncementBody(source: translation.displayedTranslation?.body ?? announcement.body)
                    .id(translation.displayedTranslation != nil)
            }
            Section {
                Button(NSLocalizedString("不再显示", comment: "")) {
                    guard isActive else { return }
                    AnnouncementManager.shared.hideAnnouncement(announcement); dismiss()
                }
            }
        }
        .formStyle(.grouped).navigationTitle(translation.displayedTranslation?.title ?? announcement.title).disabled(!isActive)
        .announcementTranslation(for: announcement, model: translation, isActive: isActive)
        .announcementDetailGuide(id: GuidePageID(rawValue: "mac-announcement-\(announcement.id)"),
                                 announcement: announcement, model: translation, isActive: isActive)
    }
}

private struct MacAnnouncementBody: View {
    let source: String
    @State private var prepared: MacPreparedMessageText?

    var body: some View {
        Group {
            if let prepared { MacMessageTextView(text: prepared) }
            else { Text(verbatim: source) }
        }
        .task {
            let text = await Task.detached(priority: .utility) { [source] in
                MacPreparedMessageText(source, markdown: true)
            }.value
            if !Task.isCancelled { prepared = text }
        }
    }
}
