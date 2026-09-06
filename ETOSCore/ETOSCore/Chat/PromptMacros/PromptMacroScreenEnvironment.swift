import Foundation
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

enum PromptMacroScreenEnvironment {
    @MainActor
    static func capture() -> [String: String] {
        #if os(iOS)
        // 从 App 所在的屏幕取值，后台没有关联场景时保留 unknown，不猜测屏幕或唤醒 UI。
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
        guard let screen = scene?.screen else {
            return Dictionary(uniqueKeysWithValues: PromptMacroResolver.screenNames.map { ($0, "unknown") })
        }
        return values(bounds: screen.bounds, scale: screen.scale, brightness: Float(screen.brightness))
        #elseif os(watchOS)
        let device = WKInterfaceDevice.current()
        // WatchKit 提供尺寸与缩放倍率，未开放当前屏幕亮度读数。
        return values(bounds: device.screenBounds, scale: device.screenScale, brightness: nil)
        #else
        return Dictionary(uniqueKeysWithValues: PromptMacroResolver.screenNames.map { ($0, "unknown") })
        #endif
    }

    static func values(bounds: CGRect, scale: CGFloat, brightness: Float?) -> [String: String] {
        [
            "screen_brightness": brightness.map { PromptMacroEnvironment.percentageValue($0) } ?? "unknown",
            "screen_width": String(Int(bounds.width)),
            "screen_height": String(Int(bounds.height)),
            "screen_scale": String(Double(scale))
        ]
    }
}
