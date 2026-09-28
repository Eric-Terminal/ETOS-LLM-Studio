import ETOSCore
import Testing
@testable import ETOS_LLM_Studio_Watch_App

@MainActor
@Suite("手表页面操作菜单")
struct WatchPageActionsPresentationTests {
    @Test("选择保存后等待菜单关闭再执行，重复关闭不会再次保存")
    func defersActionUntilDismissal() {
        let coordinator = GuideContextCoordinator()
        var presentation = WatchPageActionsPresentation(coordinator: coordinator)
        var saves = 0
        let save = WatchPageAction(title: "保存", systemImage: "checkmark") { saves += 1 }

        presentation.present()
        #expect(presentation.isPresented)
        presentation.select(save)
        #expect(!presentation.isPresented)
        #expect(saves == 0)

        presentation.didDismiss()
        #expect(saves == 1)
        presentation.didDismiss()
        #expect(saves == 1)

        presentation.present()
        presentation.isPresented = false
        presentation.didDismiss()
        #expect(saves == 1)
    }

    @Test("操作列表和向导保留来源页，执行页面操作前释放固定上下文")
    func sourceContextLivesUntilDismissal() {
        let coordinator = GuideContextCoordinator()
        let source = coordinator.register(
            descriptor: GuidePageDescriptor(id: "editor", title: "编辑器"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        var presentation = WatchPageActionsPresentation(coordinator: coordinator)
        presentation.present()
        coordinator.unregister(source)
        coordinator.register(
            descriptor: GuidePageDescriptor(id: "parent", title: "设置"),
            snapshot: { .empty },
            buildProposal: { _, _ in throw GuideError.invalidToolArguments },
            execute: { _ in throw GuideError.invalidToolArguments }
        )
        #expect(coordinator.activePage?.id == "editor")

        var contextDuringAction: GuidePageID?
        presentation.select(WatchPageAction(title: "保存", systemImage: "checkmark") {
            contextDuringAction = coordinator.activePage?.id
        })
        #expect(coordinator.activePage?.id == "editor")
        #expect(contextDuringAction == nil)
        presentation.didDismiss()
        #expect(contextDuringAction == "parent")
        #expect(coordinator.activePage?.id == "parent")
    }
}
