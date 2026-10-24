import Darwin
import ETOSCore
import SwiftUI
import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@Suite("批量任务设置导航", .serialized)
@MainActor
struct BatchNavigationRuntimeTests {
    @Test("从拓展功能进入新建页和介绍页后保持导航层级，返回恢复来源页")
    func opensNestedPagesWithoutPoppingSettings() async throws {
        // 与现有页面运行时测试一致，仅在测试宿主启用系统无障碍动作桥。
        let libraryPath = (ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? "")
            + "/usr/lib/libAccessibility.dylib"
        let library = try #require(dlopen(libraryPath, RTLD_LAZY), "无法加载测试用无障碍自动化桥")
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
        let model = ChatViewModel(chatService: ChatService())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: NavigationStack {
            ExtendedFeaturesView().environmentObject(model)
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        try await waitForPage("settings-extended-features")
        try await activate("batch.tasks.entry", in: host.view)
        try await waitForPage("batch-tasks")
        let navigation = try #require(navigationController(in: host))
        let listDepth = navigation.viewControllers.count
        #expect(listDepth > 1, "必须从真实拓展功能入口进入，覆盖视图导航父页面")

        for (identifier, pageID) in [("batch.new", "batch-editor"), ("batch.introduction", "batch-introduction")] {
            try await activate(identifier, in: host.view)
            try await waitForPage(pageID)
            #expect(navigation.viewControllers.count == listDepth + 1)

            // 列表更新不能移除已经打开的新建页，也不能抢走它的向导上下文。
            NotificationCenter.default.post(name: .batchJobsChanged, object: nil)
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(50))
                #expect(navigation.viewControllers.count == listDepth + 1)
                #expect(GuideContextCoordinator.shared.activePage?.id.rawValue == pageID)
            }

            _ = navigation.popViewController(animated: false)
            try await waitForPage("batch-tasks")
            #expect(navigation.viewControllers.count == listDepth)
        }

        _ = navigation.popViewController(animated: false)
        try await waitForPage("settings-extended-features")
    }

    private func waitForPage(_ pageID: String) async throws {
        for _ in 0..<100 {
            if GuideContextCoordinator.shared.activePage?.id.rawValue == pageID { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(GuideContextCoordinator.shared.activePage?.id.rawValue == pageID,
                     "导航后应激活当前页面的向导上下文")
    }

    private func activate(_ identifier: String, in view: UIView) async throws {
        for _ in 0..<100 {
            view.layoutIfNeeded()
            if let link = accessibilityObjects(view).first(where: {
                ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier
            }) {
                try #require(link.accessibilityActivate(), "应通过真实入口打开页面")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("未找到批量任务导航入口：\(identifier)")
    }

    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        for child in controller.children {
            if let navigation = navigationController(in: child) { return navigation }
        }
        return nil
    }

    private func accessibilityObjects(_ object: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 20 else { return [] }
        let children: [NSObject]
        if let elements = object.accessibilityElements, !elements.isEmpty {
            children = elements.compactMap { $0 as? NSObject }
        } else if object.accessibilityElementCount() > 0 && object.accessibilityElementCount() < 1000 {
            children = (0..<object.accessibilityElementCount()).compactMap {
                object.accessibilityElement(at: $0) as? NSObject
            }
        } else {
            children = (object as? UIView)?.subviews ?? []
        }
        return [object] + children.flatMap { accessibilityObjects($0, depth: depth + 1) }
    }
}
