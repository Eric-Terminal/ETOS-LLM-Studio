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
        let navigation = try #require(navigationController(in: host))
        let settingsDepth = navigation.viewControllers.count
        try await activate("batch.tasks.entry", in: host.view)
        try await waitForPage("batch-tasks")
        try await waitForNavigationDepth(settingsDepth + 1, in: navigation)
        let listDepth = navigation.viewControllers.count
        #expect(listDepth > 1, "必须从真实拓展功能入口进入，覆盖视图导航父页面")

        for (identifier, pageID) in [("batch.new", "batch-editor"), ("batch.introduction", "batch-introduction")] {
            try await activate(identifier, in: host.view)
            try await waitForPage(pageID)
            try await waitForNavigationDepth(listDepth + 1, in: navigation)
            #expect(navigation.viewControllers.count == listDepth + 1)

            // 列表更新不能移除已经打开的新建页，也不能抢走它的向导上下文。
            NotificationCenter.default.post(name: .batchJobsChanged, object: nil)
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(50))
                #expect(navigation.viewControllers.count == listDepth + 1)
                #expect(GuideContextCoordinator.shared.activePage?.id.rawValue == pageID)
            }

            if pageID == "batch-editor" {
                try await activate("batch.models.choose", in: host.view)
                try await waitForPage("batch-model-picker")
                try await waitForNavigationDepth(listDepth + 2, in: navigation)
                #expect(navigation.viewControllers.count == listDepth + 2)
                _ = navigation.popViewController(animated: false)
                try await waitForPage("batch-editor")

                for (entry, destination) in [("batch.request.add", "batch-request-editor-"), ("batch.request.import", "batch-request-import")] {
                    try await activate(entry, in: host.view)
                    try await waitForPage(destination, matchesPrefix: true)
                    let presented = try #require(host.presentedViewController)
                    try await activate("batch.request.cancel", in: presented.view)
                    try await waitForPage("batch-editor")
                    #expect(navigation.viewControllers.count == listDepth + 1)
                }
            }

            _ = navigation.popViewController(animated: false)
            try await waitForPage("batch-tasks")
            #expect(navigation.viewControllers.count == listDepth)
        }

        _ = navigation.popViewController(animated: false)
        try await waitForPage("settings-extended-features")
    }

    private func waitForNavigationDepth(_ depth: Int, in navigation: UINavigationController) async throws {
        // 向导在 onAppear 激活时，原生入场动画可能尚未提交新栈；刷新回归从真正显示的子页开始。
        for _ in 0..<100 {
            if navigation.viewControllers.count == depth, navigation.transitionCoordinator == nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(navigation.viewControllers.count == depth && navigation.transitionCoordinator == nil,
                     "原生导航完成后应保留预期页面层级")
    }

    private func waitForPage(_ pageID: String, matchesPrefix: Bool = false) async throws {
        for _ in 0..<100 {
            let current = GuideContextCoordinator.shared.activePage?.id.rawValue
            if matchesPrefix ? current?.hasPrefix(pageID) == true : current == pageID { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(GuideContextCoordinator.shared.activePage?.id.rawValue == pageID,
                     "导航后应激活当前页面的向导上下文")
    }

    private func activate(_ identifier: String, in view: UIView) async throws {
        for _ in 0..<100 {
            view.layoutIfNeeded()
            if let link = accessibilityObjects(view).first(where: {
                accessibilityIdentifier(of: $0) == identifier
            }) {
                try #require(link.accessibilityActivate(), "应通过真实入口打开页面")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let elements = accessibilityObjects(view).map {
            "\(type(of: $0)) id=\(accessibilityIdentifier(of: $0) ?? "") label=\($0.accessibilityLabel ?? "")"
        }.joined(separator: "\n")
        Attachment.record(Data(elements.utf8), named: "批量导航入口-\(identifier).txt")
        let png = UIGraphicsImageRenderer(bounds: view.bounds).pngData { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        Attachment.record(png, named: "批量导航入口-\(identifier).png")
        let link = try #require(accessibilityObjects(view).first { accessibilityIdentifier(of: $0) == identifier },
                               "未找到批量任务导航入口：\(identifier)")
        try #require(link.accessibilityActivate(), "应通过真实入口打开页面")
    }

    private func accessibilityIdentifier(of object: NSObject) -> String? {
        // SwiftUI 的 AccessibilityNode 提供 ObjC getter，但不一定声明遵循 UIKit 的标识协议。
        guard object.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
        return object.value(forKey: "accessibilityIdentifier") as? String
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
