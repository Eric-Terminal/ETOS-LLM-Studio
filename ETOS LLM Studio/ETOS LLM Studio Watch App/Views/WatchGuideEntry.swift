import SwiftUI
import ETOSCore

/// 页面显式提供原有操作，避免向导和保存、添加等按钮争用手表唯一的右侧工具栏位置。
struct WatchPageAction {
    let title: String
    let systemImage: String
    var isEnabled = true
    var role: ButtonRole? = nil
    let perform: () -> Void
}

/// 操作菜单关闭后再交还来源页执行动作，避免菜单和编辑器同时请求呈现弹窗。
@MainActor
struct WatchPageActionsPresentation {
    var isPresented = false
    private var pendingAction: (() -> Void)?
    private let coordinator: GuideContextCoordinator

    init(coordinator: GuideContextCoordinator) {
        self.coordinator = coordinator
    }

    mutating func present() {
        coordinator.pinActivePage()
        isPresented = true
    }

    mutating func select(_ action: WatchPageAction) {
        pendingAction = action.perform
        isPresented = false
    }

    mutating func didDismiss() {
        coordinator.unpinActivePage()
        let action = pendingAction
        pendingAction = nil
        action?()
    }
}

@MainActor
private struct WatchGuideEntryModifier: ViewModifier {
    @EnvironmentObject private var controller: GuideConversationController
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var presentation = WatchPageActionsPresentation(coordinator: .shared)

    let actions: [WatchPageAction]

    func body(content: Content) -> some View {
        content
            .toolbar {
                if appConfig.guideOverlayEnabled || !actions.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            presentation.present()
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel(NSLocalizedString("watch.page.actions.title", value: "More Actions", comment: "手表页面操作菜单"))
                        .accessibilityIdentifier("watchPageActions")
                    }
                }
            }
            .sheet(isPresented: $presentation.isPresented, onDismiss: {
                presentation.didDismiss()
            }) {
                NavigationStack {
                    List {
                        if !actions.isEmpty {
                            Section {
                                ForEach(actions.indices, id: \.self) { index in
                                    let action = actions[index]
                                    Button(role: action.role) {
                                        presentation.select(action)
                                    } label: {
                                        Label(action.title, systemImage: action.systemImage)
                                    }
                                    .disabled(!action.isEnabled)
                                }
                            }
                        }
                        if appConfig.guideOverlayEnabled {
                            Section {
                                NavigationLink {
                                    WatchGuideConversationView(controller: controller) {
                                        presentation.isPresented = false
                                    }
                                } label: {
                                    Label(NSLocalizedString("询问当前页面", comment: "手表当前页面向导入口"), systemImage: "questionmark.bubble")
                                }
                                .accessibilityIdentifier("watchGuideEntry")
                            }
                        }
                    }
                    .navigationTitle(NSLocalizedString("watch.page.actions.title", value: "More Actions", comment: "手表页面操作菜单"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(NSLocalizedString("关闭", comment: "关闭手表页面操作菜单")) {
                                presentation.isPresented = false
                            }
                        }
                    }
                }
                // 菜单及其向导共用来源页；进入向导或其子页时不释放固定上下文。
            }
    }
}

extension View {
    func watchGuideEntry(actions: [WatchPageAction] = []) -> some View {
        modifier(WatchGuideEntryModifier(actions: actions))
    }
}
