import Darwin
import Foundation
import UIKit

enum ChatToolbarDevicePolicy {
    @MainActor
    static let currentUsesSystemToolbar: Bool = {
        guard #available(iOS 27.1, *) else { return false }

        let modelIdentifier: String
        #if targetEnvironment(simulator)
        // 模拟器的 uname 返回宿主架构，必须读取被模拟的机型。
        modelIdentifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        #else
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return false }
        modelIdentifier = withUnsafeBytes(of: systemInfo.machine) { bytes in
            String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        #endif

        return usesSystemToolbar(
            idiom: UIDevice.current.userInterfaceIdiom,
            modelIdentifier: modelIdentifier
        )
    }()

    static func usesSystemToolbar(idiom: UIUserInterfaceIdiom, modelIdentifier: String) -> Bool {
        // iPad 等设备沿用现有行为；普通 iPhone 恢复自定义导航。
        guard idiom == .phone else { return true }
        // 来自 Xcode 的 iPhone Duo.simdevicetype/profile.plist。
        // 机型不随内外屏、折痕和窗口宽度变化，避免折叠过程中切换导航实现。
        return modelIdentifier == "iPhone19,4"
    }
}
