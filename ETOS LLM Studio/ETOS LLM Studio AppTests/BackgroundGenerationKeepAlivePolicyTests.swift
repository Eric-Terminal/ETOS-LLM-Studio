// ============================================================================
// BackgroundGenerationKeepAlivePolicyTests.swift
// ============================================================================

import CoreLocation
import ETOSCore
import Testing
@testable import ETOS_LLM_Studio_App

@Suite("后台持续生成策略测试")
struct BackgroundGenerationKeepAlivePolicyTests {
    @Test("只有用户开启、存在生成任务且定位可用时才启动")
    func activatesOnlyWhenEveryRequirementIsMet() {
        #expect(BackgroundGenerationKeepAlivePolicy.shouldActivate(
            featureEnabled: true,
            hasActiveGeneration: true,
            locationServicesEnabled: true,
            authorizationStatus: .authorizedWhenInUse
        ))

        #expect(!BackgroundGenerationKeepAlivePolicy.shouldActivate(
            featureEnabled: false,
            hasActiveGeneration: true,
            locationServicesEnabled: true,
            authorizationStatus: .authorizedWhenInUse
        ))

        #expect(!BackgroundGenerationKeepAlivePolicy.shouldActivate(
            featureEnabled: true,
            hasActiveGeneration: false,
            locationServicesEnabled: true,
            authorizationStatus: .authorizedWhenInUse
        ))

        #expect(!BackgroundGenerationKeepAlivePolicy.shouldActivate(
            featureEnabled: true,
            hasActiveGeneration: true,
            locationServicesEnabled: false,
            authorizationStatus: .authorizedWhenInUse
        ))

        #expect(!BackgroundGenerationKeepAlivePolicy.shouldActivate(
            featureEnabled: true,
            hasActiveGeneration: true,
            locationServicesEnabled: true,
            authorizationStatus: .denied
        ))
    }

    @Test("使用期间与始终定位权限均可维持后台活动")
    func acceptsUsableLocationAuthorizations() {
        #expect(BackgroundGenerationKeepAlivePolicy.hasUsableAuthorization(.authorizedWhenInUse))
        #expect(BackgroundGenerationKeepAlivePolicy.hasUsableAuthorization(.authorizedAlways))
        #expect(!BackgroundGenerationKeepAlivePolicy.hasUsableAuthorization(.notDetermined))
        #expect(!BackgroundGenerationKeepAlivePolicy.hasUsableAuthorization(.restricted))
    }

    @Test("后台持续生成默认关闭且不跨设备同步")
    func preferenceDefaultsToLocalOptIn() {
        let key = AppConfigKey.backgroundGenerationKeepAliveEnabled
        #expect(key.defaultValue == .bool(false))
        #expect(!key.participatesInSync)
    }
}
