// ============================================================================
// ETOS_LLM_Studio_Watch_AppUITestsLaunchTests.swift
// ============================================================================
// ETOS_LLM_Studio_Watch_AppUITestsLaunchTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

//
//  ETOS_LLM_Studio_Watch_AppUITestsLaunchTests.swift
//  ETOS LLM Studio Watch AppUITests
//
//  Created by Eric on 2026/1/10.
//

import XCTest

final class ETOS_LLM_Studio_Watch_AppUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
