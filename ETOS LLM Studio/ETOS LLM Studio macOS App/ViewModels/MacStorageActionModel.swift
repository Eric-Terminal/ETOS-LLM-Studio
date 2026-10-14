import Combine
import ETOSCore
import Foundation

@MainActor
final class MacStorageActionModel: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var report: String?
    @Published private(set) var error: String?

    func clear() { guard !isWorking else { return }; report = nil; error = nil }

    func perform(_ mutation: MacStorageMutation, workspace: MacWorkspaceModel) async {
        guard !isWorking, workspace.canManageLocalModels else { return }
        isWorking = true; report = nil; error = nil
        let language = AppConfigStore.shared.appLanguage
        defer { isWorking = false }
        do {
            let report = try await workspace.dataImportOperations.perform {
                try await workspace.performDataMaintenance { _ in
                    try await Task.detached(priority: .utility) { try mutation.apply() }.value
                }
            }
            if workspace.canManageLocalModels, AppConfigStore.shared.appLanguage == language { self.report = report }
        } catch {
            if workspace.canManageLocalModels, AppConfigStore.shared.appLanguage == language { self.error = error.localizedDescription }
        }
    }
}
