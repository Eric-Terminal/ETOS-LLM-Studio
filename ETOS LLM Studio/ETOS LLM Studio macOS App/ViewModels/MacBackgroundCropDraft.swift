import Combine
import Foundation

@MainActor
final class MacBackgroundCropDraft: ObservableObject, Identifiable {
    let id = UUID()
    let file: MacBackgroundFile
    let sourceEpoch: UUID
    @Published var parameters = MacBackgroundCropParameters()
    @Published var prepared: MacPreparedBackgroundCrop?
    @Published var isPreparing = true
    @Published var error: String?

    init(file: MacBackgroundFile, sourceEpoch: UUID) {
        self.file = file; self.sourceEpoch = sourceEpoch
    }

    func reset() {
        parameters.zoom = 1; parameters.horizontal = 0.5; parameters.vertical = 0.5
    }
}
