import Foundation
import SwiftUI
import ETOSCore

extension Notification.Name {
    static let requestIncomingSnapshotRestore = Notification.Name("ios.requestIncomingSnapshotRestore")
}

struct IncomingSnapshotRestorePayload: Identifiable {
    let id = UUID()
    let fileURL: URL
}

enum IncomingSnapshotRestoreSupport {
    static func isSnapshotURL(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.caseInsensitiveCompare(SnapshotBuilder.fileExtension) == .orderedSame
    }
}

struct IncomingSnapshotRestoreView: View {
    let fileURL: URL
    let onDismiss: () -> Void

    var body: some View {
        SnapshotImportRestoreView(fileURL: fileURL, onDismiss: onDismiss)
    }
}
