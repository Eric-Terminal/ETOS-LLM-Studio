import Darwin
import ETOSCore
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("提供商发送入口与可见反馈", .serialized)
@MainActor
struct ProviderTransferRuntimeTests {
    @Test("列表底部的原生菜单触发发送，关闭同步时仍显示失败面板并恢复向导上下文")
    func contextMenuPresentsVisibleFailure() async throws {
        let libraryPath = (ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? "")
            + "/usr/lib/libAccessibility.dylib"
        let library = try #require(dlopen(libraryPath, RTLD_LAZY))
        defer { dlclose(library) }
        let readAutomation = unsafeBitCast(
            try #require(dlsym(library, "_AXSAutomationEnabled")),
            to: (@convention(c) () -> Int32).self
        )
        let setAutomation = unsafeBitCast(
            try #require(dlsym(library, "_AXSSetAutomationEnabled")),
            to: (@convention(c) (Int32) -> Void).self
        )
        let previousAutomation = readAutomation()
        setAutomation(1)
        defer { setAutomation(previousAutomation) }

        await AppConfigStore.shared.waitForPersistentStoreLoaded()
        let previousSync = AppConfigStore.shared.syncAutoSyncEnabled
        // 使用真实失败分支验证按钮已调用发送入口，同时保证测试不向配对设备发送任何配置。
        AppConfigStore.shared.syncAutoSyncEnabled = false
        defer { AppConfigStore.shared.syncAutoSyncEnabled = previousSync }

        let model = ChatViewModel(chatService: ChatService())
        let providers = (1...24).map {
            Provider(name: "菜单回归提供商 \($0)", baseURL: "https://example.com/v1", apiKeys: [], apiFormat: "openai-compatible")
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: NavigationStack {
            ProviderListView().environmentObject(model)
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        try await waitUntil { GuideContextCoordinator.shared.activePage?.id.rawValue == "provider-list" }
        model.providers = providers
        try await waitUntil {
            self.views(in: host.view).compactMap { $0 as? UICollectionView }.contains {
                $0.numberOfSections > 1 && $0.numberOfItems(inSection: 1) == providers.count
            }
        }
        let list = try #require(views(in: host.view).compactMap { $0 as? UICollectionView }.first {
            $0.numberOfSections > 1 && $0.numberOfItems(inSection: 1) == providers.count
        })
        let indexPath = IndexPath(item: providers.count - 1, section: 1)
        list.scrollToItem(at: indexPath, at: .bottom, animated: false)
        try await waitUntil { list.cellForItem(at: indexPath) != nil }
        #expect(list.contentOffset.y > 0, "必须从已滚动的列表底部触发，覆盖旧提示被遮住的问题")
        #expect(list.dataSource?.collectionView?(list, canMoveItemAt: indexPath) != true,
                "提供商管理行不能再注册排序移动操作，与长按菜单争抢手势")

        let cell = try #require(list.cellForItem(at: indexPath))
        let configuration = try #require(list.delegate?.collectionView?(
            list,
            contextMenuConfigurationForItemsAt: [indexPath],
            point: CGPoint(x: cell.frame.midX, y: cell.frame.midY)
        ))
        // 仅在测试宿主读取 UIKit 已生成的菜单，不替换业务回调，也不伪造传输结果。
        // 这覆盖原生菜单与发送入口的接线；物理长按的识别还需模拟器手势回归。
        let selector = NSSelectorFromString("actionProvider")
        try #require(configuration.responds(to: selector), "应能读取系统菜单生成器")
        let block = try #require(configuration.value(forKey: "actionProvider")) as AnyObject
        let actionProvider = unsafeBitCast(block, to: (@convention(block) (NSArray) -> UIMenu?).self)
        let menu = try #require(actionProvider([]))
        let send = try #require(actions(in: menu).first {
            $0.title == NSLocalizedString("发送到 Apple Watch", comment: "")
        })
        #expect(!send.attributes.contains(.disabled))
        UIControl().sendAction(send)

        try await waitUntil { GuideContextCoordinator.shared.activePage?.id.rawValue == "provider-transfer-status" }
        let panel = try #require(host.presentedViewController)
        let failure = NSLocalizedString("同步已关闭，已阻止向对端传输数据。", comment: "")
        #expect(WatchSyncManager.shared.state == .failed(failure), "菜单按钮必须进入真实发送校验")
        try await waitUntil {
            self.accessibilityObjects(panel.view).contains { $0.accessibilityLabel?.contains(failure) == true }
        }
        let png = UIGraphicsImageRenderer(bounds: panel.view.bounds).pngData { _ in
            panel.view.drawHierarchy(in: panel.view.bounds, afterScreenUpdates: true)
        }
        Attachment.record(png, named: "提供商发送失败可见反馈.png")
        let done = try #require(accessibilityObjects(panel.view).first {
            $0.responds(to: NSSelectorFromString("accessibilityIdentifier"))
                && $0.value(forKey: "accessibilityIdentifier") as? String == "provider.transfer.done"
        })
        try #require(done.accessibilityActivate())
        try await waitUntil { GuideContextCoordinator.shared.activePage?.id.rawValue == "provider-list" }
        #expect(list.indexPathsForVisibleItems.contains(indexPath), "关闭面板后应保留原列表位置")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition(), "等待原生页面和菜单状态完成更新")
    }

    private func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    private func actions(in menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { element in
            if let action = element as? UIAction { return [action] }
            if let submenu = element as? UIMenu { return actions(in: submenu) }
            return []
        }
    }

    private func accessibilityObjects(_ object: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 20 else { return [] }
        let children: [NSObject]
        if let elements = object.accessibilityElements, !elements.isEmpty {
            children = elements.compactMap { $0 as? NSObject }
        } else if object.accessibilityElementCount() > 0 && object.accessibilityElementCount() < 1000 {
            children = (0..<object.accessibilityElementCount()).compactMap { object.accessibilityElement(at: $0) as? NSObject }
        } else {
            children = (object as? UIView)?.subviews ?? []
        }
        return [object] + children.flatMap { accessibilityObjects($0, depth: depth + 1) }
    }
}
