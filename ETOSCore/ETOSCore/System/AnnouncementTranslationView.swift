import Combine
import SwiftUI

@MainActor
public final class AnnouncementTranslationModel: ObservableObject {
    fileprivate enum State {
        case unavailable, ready, translating
        case translated(AnnouncementText, showingOriginal: Bool)
        case failed(String)
    }

    @Published fileprivate var state: State = .unavailable
    private var request: Task<Void, Never>?
    private var input: (announcement: Announcement, targetLanguage: String)?

    public init() {}

    public var displayedTranslation: AnnouncementText? {
        if case let .translated(text, showingOriginal: false) = state { return text }
        return nil
    }

    fileprivate func prepare(_ announcement: Announcement, targetLanguage: String) async {
        guard !Task.isCancelled else { return }
        reset()
        let needed = await Task.detached(priority: .userInitiated) {
            AnnouncementTranslation.needsTranslation(announcement, targetLanguage: targetLanguage)
        }.value
        guard needed, !Task.isCancelled else { return }
        input = (announcement, targetLanguage)
        state = .ready
    }

    fileprivate func reset() {
        request?.cancel()
        request = nil
        input = nil
        state = .unavailable
    }

    fileprivate func activate() {
        switch state {
        case let .translated(text, showingOriginal):
            state = .translated(text, showingOriginal: !showingOriginal)
        case .ready, .failed:
            guard let input else { return }
            state = .translating
            request = Task { [weak self] in
                do {
                    let text = try await AnnouncementTranslation.translate(input.announcement, to: input.targetLanguage)
                    guard !Task.isCancelled else { return }
                    self?.state = .translated(text, showingOriginal: false)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.state = .failed(error.localizedDescription)
                }
            }
        case .unavailable, .translating:
            break
        }
    }
}

public struct AnnouncementTranslationButton: View {
    @ObservedObject private var model: AnnouncementTranslationModel

    public init(_ model: AnnouncementTranslationModel) { self.model = model }

    public var body: some View {
        switch model.state {
        case .unavailable:
            EmptyView()
        case .ready:
            Button(action: model.activate) {
                Label(NSLocalizedString("AI 翻译", value: "Translate with AI", comment: ""), systemImage: "translate")
            }
        case .translating:
            ProgressView(NSLocalizedString("正在翻译…", value: "Translating…", comment: ""))
        case let .translated(_, showingOriginal):
            Button(action: model.activate) {
                Text(showingOriginal
                     ? NSLocalizedString("查看译文", value: "Show translation", comment: "")
                     : NSLocalizedString("查看原文", value: "Show original", comment: ""))
            }
        case let .failed(message):
            Text(verbatim: message).font(.footnote).foregroundStyle(.secondary)
            Button(NSLocalizedString("重试", value: "Retry", comment: ""), action: model.activate)
        }
    }
}

private struct AnnouncementTranslationLifecycle: ViewModifier {
    struct Input: Equatable {
        let announcementKey: String
        let preference: AppLanguagePreference
        let systemLanguageRevision: Int
        let isActive: Bool
    }

    let announcement: Announcement
    let model: AnnouncementTranslationModel
    let isActive: Bool
    @ObservedObject private var config = AppConfigStore.shared
    @State private var systemLanguageRevision = 0

    init(announcement: Announcement, model: AnnouncementTranslationModel, isActive: Bool) {
        self.announcement = announcement
        self.model = model
        self.isActive = isActive
    }

    func body(content: Content) -> some View {
        let preference = AppLanguagePreference.resolved(rawValue: config.appLanguage)
        let input = Input(announcementKey: announcement.uniqueKey, preference: preference,
                          systemLanguageRevision: systemLanguageRevision, isActive: isActive)
        content
            .task(id: input) {
                guard isActive else {
                    model.reset()
                    return
                }
                await model.prepare(announcement, targetLanguage: AnnouncementTranslation.targetLanguage(for: preference))
            }
            .onDisappear { model.reset() }
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                if preference == .system { systemLanguageRevision += 1 }
            }
    }
}

@MainActor
public extension View {
    func announcementTranslation(for announcement: Announcement, model: AnnouncementTranslationModel, isActive: Bool = true) -> some View {
        modifier(AnnouncementTranslationLifecycle(announcement: announcement, model: model, isActive: isActive))
    }

    func announcementDetailGuide(id: GuidePageID, announcement: Announcement, model: AnnouncementTranslationModel, isActive: Bool = true) -> some View {
        let title = NSLocalizedString("系统公告", comment: "")
        return guideSettingsPageContext(
            id: id, title: title, documents: [GuideDocumentReference(id: "announcement-translation", title: title)],
            isActive: isActive, settings: [
                .readOnly("id", label: title) { .int(announcement.id) },
                .readOnly("can_translate", label: NSLocalizedString("AI 翻译", value: "Translate with AI", comment: "")) {
                    if case .unavailable = model.state { return .bool(false) }
                    return .bool(true)
                },
                .readOnly("showing_translation", label: NSLocalizedString("查看译文", value: "Show translation", comment: "")) {
                    .bool(model.displayedTranslation != nil)
                }
            ]
        )
    }
}
