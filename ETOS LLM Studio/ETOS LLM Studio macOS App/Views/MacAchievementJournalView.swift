import ETOSCore
import SwiftUI

struct MacAchievementJournalView: View {
    let isActive: Bool
    @StateObject private var model = MacAchievementModel()

    var body: some View {
        List {
            if model.entries.isEmpty {
                Text(NSLocalizedString("这里还没有留下记录。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Section(NSLocalizedString("已点亮", comment: "")) {
                    ForEach(model.entries) { entry in
                        HStack(alignment: .top) {
                            Image(systemName: entry.systemImageName).foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(entry.localizedTitle).font(.headline)
                                Text(entry.localizedSentence).foregroundStyle(.secondary)
                                Text(entry.localizedTriggerNote).font(.caption).foregroundStyle(.secondary)
                                Text(entry.unlockedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("成就日记", comment: ""))
        .onAppear { model.reload() }
        // 只暴露已有记录的数量，不让向导泄露尚未触发的隐藏条目。
        .guideSettingsPageContext(id: "mac-achievement-journal", title: NSLocalizedString("成就日记", comment: ""),
            documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")], isActive: isActive,
            settings: [.readOnly("entry_count", label: NSLocalizedString("已点亮", comment: ""), value: { .int(model.entries.count) })])
    }
}
