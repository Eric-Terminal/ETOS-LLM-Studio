import ETOSCore
import Foundation

/// 后台准备选项与索引，界面只读取单个会话的实际路由和现成的向导目录。
struct MacSessionModelCatalog {
    struct Row: Identifiable {
        let id: String
        let title: String
    }

    let rows: [Row]
    let availableIDs: Set<String>
    let guideIDs: [String]
    let guideValue: JSONValue
    private let modelsByID: [String: RunnableModel]

    init(models: [RunnableModel]) {
        modelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        rows = models.map { Row(id: $0.id, title: "\($0.model.displayName) · \($0.provider.name)") }
        availableIDs = Set(modelsByID.keys)
        guideIDs = [""] + rows.map(\.id)
        guideValue = .array(rows.map { .dictionary(["id": .string($0.id), "name": .string($0.title)]) })
    }

    func resolvedModel(preferredID: String?, global: RunnableModel?) -> RunnableModel? {
        // 与 Core 发送路由一致：不可用的会话绑定保留原值，本轮回退到全局模型。
        preferredID.flatMap { modelsByID[$0] } ?? global
    }
}
