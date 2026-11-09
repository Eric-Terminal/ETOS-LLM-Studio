import Testing
import UIKit
@testable import ETOS_LLM_Studio_App

@MainActor
struct ChatToolbarDevicePolicyTests {
    @Test("支持新版系统工具栏的普通 iPhone 仍使用原导航", arguments: [
        "iPhone18,3", "iPhone19,1", "iPhone19,2", "iPhone19,3", "iPhone19,40", ""
    ])
    func ordinaryPhonesKeepCustomNavigation(modelIdentifier: String) {
        #expect(!ChatToolbarDevicePolicy.usesSystemToolbar(idiom: .phone, modelIdentifier: modelIdentifier))
    }

    @Test("Duo 真机与模拟器使用同一机型标识选择原生工具栏")
    func duoKeepsSystemToolbar() {
        #expect(ChatToolbarDevicePolicy.usesSystemToolbar(idiom: .phone, modelIdentifier: "iPhone19,4"))
    }

    @Test("普通 iPhone 导航恢复不改变 iPad 的原生工具栏")
    func padKeepsExistingToolbar() {
        #expect(ChatToolbarDevicePolicy.usesSystemToolbar(idiom: .pad, modelIdentifier: "iPad16,3"))
    }
}
