import ETOSCore
import Foundation
import SwiftUI

struct MacFontCatalog: Sendable {
    let snapshot: FontLibrarySnapshot
    let assets: [FontAssetRecord]
    let names: [UUID: String]
    let guideValue: JSONValue
    init(_ snapshot: FontLibrarySnapshot) {
        self.snapshot = snapshot
        assets = snapshot.assets.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        names = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.displayName) })
        guideValue = .array(assets.map { .dictionary(["id": .string($0.id.uuidString), "name": .string($0.displayName), "enabled": .bool($0.isEnabled)]) })
    }
}

/// 列表、规则标题和向导快照在后台构建，编辑页面不扫描完整字体库。
struct MacFontDraftCatalog: Sendable {
    struct Chain: Sendable {
        let selected: [FontAssetRecord]
        let available: [FontAssetRecord]
        let guideValue: JSONValue
        let availableGuide: JSONValue
        let allowedIDs: Set<UUID>
        init(_ ids: [UUID], assets: [FontAssetRecord]) {
            let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }), used = Set(ids)
            selected = ids.compactMap { byID[$0] }
            available = assets.filter { !used.contains($0.id) }
            guideValue = .array(ids.map { .string($0.uuidString) })
            allowedIDs = Set(assets.map(\.id))
            availableGuide = .array(assets.map { .dictionary(["id": .string($0.id.uuidString), "name": .string($0.displayName)]) })
        }
    }
    struct Rule: Identifiable, Sendable { let id: String; let title: String; let value: ChatAppearanceTextFontRule }
    let roles: [FontSemanticRole: Chain]
    let rules: [Rule]
    let ruleChains: [String: Chain]
    let emptyChain: Chain
    init(_ routes: FontRouteConfiguration, assets: [FontAssetRecord]) {
        roles = Dictionary(uniqueKeysWithValues: FontSemanticRole.allCases.map { ($0, Chain(routes.chain(for: $0), assets: assets)) })
        rules = routes.customTextRules.map {
            let sample = $0.kind == .delimitedText ? $0.startDelimiter + "…" + $0.endDelimiter : $0.exactText
            return Rule(id: $0.id, title: sample, value: $0)
        }
        ruleChains = Dictionary(uniqueKeysWithValues: routes.customTextRules.map { ($0.id, Chain($0.fontAssetIDs, assets: assets)) })
        emptyChain = Chain([], assets: assets)
    }
}
