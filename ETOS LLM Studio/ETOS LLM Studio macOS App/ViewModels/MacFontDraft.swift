import Combine
import ETOSCore
import Foundation

@MainActor
final class MacFontDraft: ObservableObject {
    @Published private(set) var routes: FontRouteConfiguration
    @Published private(set) var catalog: MacFontDraftCatalog?
    @Published private(set) var isWorking = false
    @Published private(set) var revision = UUID()
    let assets: [FontAssetRecord]
    private var task: Task<Void, Never>?
    init(_ source: MacFontCatalog) { routes = source.snapshot.routes; assets = source.assets; change { _ in } }

    func change(_ operation: @escaping @Sendable (inout FontRouteConfiguration) -> Void) {
        guard !isWorking else { return }
        isWorking = true
        let source = routes, assets = assets
        task = Task { [weak self] in
            let result = await Task.detached {
                var routes = source; operation(&routes)
                return (routes, MacFontDraftCatalog(routes, assets: assets))
            }.value
            guard let self else { return }
            routes = result.0; catalog = result.1; revision = UUID(); isWorking = false
        }
    }

    func setRule(_ rule: ChatAppearanceTextFontRule) {
        change { routes in
            if let index = routes.customTextRules.firstIndex(where: { $0.id == rule.id }) { routes.customTextRules[index] = rule }
            else { routes.customTextRules.append(rule) }
        }
    }
    func waitForPendingChanges() async { await task?.value }
}

@MainActor
final class MacFontRuleDraft: ObservableObject {
    @Published var rule: ChatAppearanceTextFontRule
    @Published private(set) var chain: MacFontDraftCatalog.Chain
    @Published private(set) var isWorking = false
    @Published private(set) var revision = UUID()
    let assets: [FontAssetRecord]
    init(rule: ChatAppearanceTextFontRule, chain: MacFontDraftCatalog.Chain, assets: [FontAssetRecord]) {
        self.rule = rule; self.chain = chain; self.assets = assets
    }
    func replaceChain(_ ids: [UUID]) async {
        guard !isWorking else { return }; isWorking = true
        let assets = assets
        let chain = await Task.detached { MacFontDraftCatalog.Chain(ids, assets: assets) }.value
        rule.fontAssetIDs = ids; self.chain = chain; revision = UUID(); isWorking = false
    }
}
