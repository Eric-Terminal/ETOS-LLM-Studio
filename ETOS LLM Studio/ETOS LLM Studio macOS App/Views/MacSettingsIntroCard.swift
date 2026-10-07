import ETOSCore
import SwiftUI

struct MacSettingsIntroCard: View {
    let id: String
    let title: String
    let details: String
    let documentID: String
    var isActive = true

    var body: some View {
        NavigationLink {
            Form {
                Section {
                    Text(details).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-introduction-\(id)"), title: title,
                documents: [GuideDocumentReference(id: documentID, title: title)],
                isActive: isActive,
                settings: [.readOnly("read_only", label: NSLocalizedString("使用说明", comment: ""), value: { .bool(true) })]
            )
        } label: {
            VStack(alignment: .leading) {
                Label(title, systemImage: "info.circle")
                Text(NSLocalizedString("进一步了解…", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
