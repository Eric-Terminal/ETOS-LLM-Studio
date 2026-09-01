// ============================================================================
// HardwareKeyboardReturnConfigTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证 iOS 实体键盘发送偏好的默认值与同步边界。
// ============================================================================

import Testing
@testable import ETOSCore

struct HardwareKeyboardReturnConfigTests {
    @Test("iOS 实体键盘默认使用 Return 发送且不参与双端同步")
    func defaultValueAndSyncBoundary() {
        let key = AppConfigKey.iOSHardwareKeyboardReturnSendsMessage

        #expect(key.defaultValue == .bool(true))
        #expect(!key.participatesInSync)
    }
}
