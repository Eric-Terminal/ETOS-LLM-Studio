import Foundation
import Testing
@testable import ETOSCore

@Suite("批量任务草稿与模型筛选")
struct BatchDraftTests {
    private let models = [
        BatchModelOption(id: "a-fast", providerID: "a", providerName: "甲提供商", name: "快速模型", modelName: "fast-v2"),
        BatchModelOption(id: "a-deep", providerID: "a", providerName: "甲提供商", name: "推理模型", modelName: "deep-v1"),
        BatchModelOption(id: "b-fast", providerID: "b", providerName: "乙提供商", name: "快速模型", modelName: "fast-v3")
    ]

    @Test("模型名称、实际 ID 和提供商均可搜索，同名模型保持独立身份")
    func searchesModelCatalog() {
        for query in ["快速", "FAST", "  fast  "] {
            let filtered = snapshot(search: query)
            #expect(filtered.visibleIDs == ["a-fast", "b-fast"])
        }
        #expect(snapshot(search: "甲提供商").visibleIDs == ["a-fast", "a-deep"])
        #expect(snapshot(search: "fast", provider: "b").visibleIDs == ["b-fast"])
        #expect(snapshot(search: "不存在").groups.isEmpty)
    }

    @Test("搜索与已选筛选不改变实际提交目标，摘要按请求数乘模型数计算")
    func selectionAndSubmissionAreIndependentOfFilters() {
        let snapshot = BatchDraftSnapshot.make(requests: [BatchDraftRequest(text: "第一条\n第二段"), BatchDraftRequest(text: "另一条")],
            models: models, selectedIDs: ["a-fast", "a-deep"], search: "fast", providerID: "a", selectedOnly: true)
        #expect(snapshot.visibleIDs == ["a-fast"])
        #expect(snapshot.selectedModels.map(\.id) == ["a-fast", "a-deep"])
        #expect(snapshot.inputs == ["第一条\n第二段", "另一条"])
        #expect(snapshot.canSubmit)
        #expect(snapshot.totalSummary == String(format:
            NSLocalizedString("batch.review.total", value: "%d requests in total · %d remote tasks", comment: ""), 4, 2))
    }

    @Test("全选及取消仅作用于当前结果，等待新筛选时不能误选旧范围")
    @MainActor
    func scopedBulkSelection() async {
        let draft = BatchDraftModel()
        draft.configure(models: models)
        draft.select("b-fast", selected: true)
        draft.providerID = "a"
        draft.selectVisible(true)
        #expect(draft.selectedIDs == ["b-fast"])
        await draft.waitForUpdates()
        draft.selectVisible(true)
        await draft.waitForUpdates()
        #expect(draft.selectedIDs == ["a-fast", "a-deep", "b-fast"])
        #expect(draft.snapshot.allVisibleSelected)
        draft.selectVisible(false)
        await draft.waitForUpdates()
        #expect(draft.selectedIDs == ["b-fast"])
        draft.selectedOnly = true
        await draft.waitForUpdates()
        #expect(draft.snapshot.visibleIDs.isEmpty)
        #expect(!draft.snapshot.allVisibleSelected)
    }

    @Test("逐条编辑保留换行与身份，仅显式按行导入拆分请求")
    @MainActor
    func preservesMultilineRequests() async {
        let draft = BatchDraftModel()
        let id = UUID()
        await draft.saveRequest(id: id, text: "  首段\n\n第二段  ")
        await draft.waitForUpdates()
        #expect(draft.snapshot.inputs == ["首段\n\n第二段"])
        await draft.saveRequest(id: id, text: "更新\n仍是一条")
        await draft.appendLines("A\r\n \r\nB\nC")
        await draft.waitForUpdates()
        #expect(draft.snapshot.inputs == ["更新\n仍是一条", "A", "B", "C"])
        #expect(draft.requests[0].id == id)
        #expect(Set(draft.requests.map(\.id)).count == 4)
        await draft.saveRequest(id: UUID(), text: " \n ")
        #expect(draft.requests.count == 4)
        draft.removeRequests(at: IndexSet([0, 2]))
        await draft.waitForUpdates()
        #expect(draft.snapshot.inputs == ["A", "C"])
        draft.removeRequest(id: draft.requests[0].id)
        await draft.waitForUpdates()
        #expect(draft.snapshot.inputs == ["C"])
    }

    @Test("被删除或停用的候选不再提交，重新配置不丢失正文草稿")
    @MainActor
    func removesUnavailableModels() async {
        let draft = BatchDraftModel()
        draft.configure(models: models)
        draft.select("a-fast", selected: true)
        draft.providerID = "a"
        await draft.saveRequest(id: UUID(), text: "完整正文")
        await draft.waitForUpdates()
        #expect(draft.canSubmit)
        draft.configure(models: Array(models.suffix(1)))
        #expect(!draft.canSubmit)
        await draft.waitForUpdates()
        #expect(draft.selectedIDs.isEmpty)
        #expect(draft.providerID.isEmpty)
        #expect(draft.snapshot.inputs == ["完整正文"])
        #expect(!draft.canSubmit)
    }

    @Test("大量候选快速切换筛选后只发布最后一次结果")
    @MainActor
    func latestFilterWins() async {
        let draft = BatchDraftModel()
        let catalog = (0..<600).map {
            BatchModelOption(id: "model-\($0)", providerID: "provider-\($0 % 3)", providerName: "提供商 \($0 % 3)",
                             name: "模型 \($0)", modelName: "model-\($0)")
        }
        draft.configure(models: catalog)
        draft.search = "model-1"
        draft.search = "model-599"
        await draft.waitForUpdates()
        #expect(draft.snapshot.visibleIDs == ["model-599"])
        #expect(draft.snapshot.providers.count == 3)
    }

    @Test("根草稿不公开正文，模型页仅公开当前筛选结果的可写选择")
    @MainActor
    func guideFieldsFollowCurrentPage() async {
        let draft = BatchDraftModel()
        draft.configure(models: models)
        draft.providerID = "b"
        await draft.waitForUpdates()
        #expect(Set(draft.guideSettings.map(\.key)) == ["title", "request_count", "models", "draft_only"])
        #expect(draft.pickerGuideSettings.contains { $0.key == "model_b-fast" && $0.access == .readWrite })
        #expect(!draft.pickerGuideSettings.contains { $0.key == "model_a-fast" })
        #expect(draft.pickerGuideSettings.contains { $0.key == "provider_filter" && $0.access == .readWrite })
    }

    private func snapshot(search: String = "", provider: String = "") -> BatchDraftSnapshot {
        BatchDraftSnapshot.make(requests: [], models: models, selectedIDs: [], search: search, providerID: provider, selectedOnly: false)
    }
}
