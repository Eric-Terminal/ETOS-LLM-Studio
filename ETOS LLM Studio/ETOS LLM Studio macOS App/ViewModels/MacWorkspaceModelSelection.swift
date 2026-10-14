import ETOSCore
import Foundation

extension MacWorkspaceModel {
    func selectModel(_ id: String?) {
        guard canManageLocalModels, let service, let id,
              let model = sessionModelCatalog.resolvedModel(preferredID: id, global: nil) else { return }
        Task.detached(priority: .userInitiated) { service.setSelectedModel(model) }
    }
}
