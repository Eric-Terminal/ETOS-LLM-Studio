// ============================================================================
// BackgroundGenerationKeepAliveManager.swift
// ============================================================================
// ETOS LLM Studio
//
// 仅在用户主动启用且模型正在生成回复时持有系统定位后台活动会话。
// 本功能不请求位置更新，也不读取、保存或上传位置坐标。
// ============================================================================

import Combine
@preconcurrency import CoreLocation
import ETOSCore
import UIKit

enum BackgroundGenerationKeepAlivePolicy {
    static func hasUsableAuthorization(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    static func shouldActivate(
        featureEnabled: Bool,
        hasActiveGeneration: Bool,
        locationServicesEnabled: Bool,
        authorizationStatus: CLAuthorizationStatus
    ) -> Bool {
        featureEnabled
            && hasActiveGeneration
            && locationServicesEnabled
            && hasUsableAuthorization(authorizationStatus)
    }
}

@MainActor
final class BackgroundGenerationKeepAliveManager: NSObject, ObservableObject {
    static let shared = BackgroundGenerationKeepAliveManager()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var locationServicesEnabled: Bool
    @Published private(set) var isActivitySessionActive = false

    private let locationManager: CLLocationManager
    private var backgroundActivitySession: CLBackgroundActivitySession?
    private var hasActiveGeneration = false

    private override init() {
        let locationManager = CLLocationManager()
        self.locationManager = locationManager
        authorizationStatus = locationManager.authorizationStatus
        locationServicesEnabled = false
        super.init()
        locationManager.delegate = self
        refreshLocationServicesAvailability()
    }

    func setFeatureEnabled(_ enabled: Bool) {
        AppConfigStore.shared.backgroundGenerationKeepAliveEnabled = enabled
        if enabled {
            requestAuthorizationIfNeeded()
        }
        updateActivitySession()
    }

    func setGenerationActive(_ isActive: Bool) {
        guard hasActiveGeneration != isActive else {
            updateActivitySession()
            return
        }
        hasActiveGeneration = isActive
        updateActivitySession()
    }

    func refreshStatus() {
        authorizationStatus = locationManager.authorizationStatus
        refreshLocationServicesAvailability()
    }

    func requestAuthorizationIfNeeded() {
        refreshStatus()
        guard authorizationStatus == .notDetermined else { return }
        locationManager.requestWhenInUseAuthorization()
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func updateActivitySession() {
        let shouldActivate = BackgroundGenerationKeepAlivePolicy.shouldActivate(
            featureEnabled: AppConfigStore.shared.backgroundGenerationKeepAliveEnabled,
            hasActiveGeneration: hasActiveGeneration,
            locationServicesEnabled: locationServicesEnabled,
            authorizationStatus: authorizationStatus
        )

        if shouldActivate {
            guard backgroundActivitySession == nil else { return }
            // 必须在前台开始并持续持有；释放对象会让系统立即结束后台活动。
            backgroundActivitySession = CLBackgroundActivitySession()
            isActivitySessionActive = true
        } else {
            stopActivitySession()
        }
    }

    private func stopActivitySession() {
        backgroundActivitySession?.invalidate()
        backgroundActivitySession = nil
        isActivitySessionActive = false
    }

    private func applyAuthorizationStatus(
        _ status: CLAuthorizationStatus,
        locationServicesEnabled: Bool
    ) {
        authorizationStatus = status
        self.locationServicesEnabled = locationServicesEnabled
        updateActivitySession()
    }

    private func refreshLocationServicesAvailability() {
        Task { @MainActor [weak self] in
            let isEnabled = await Task.detached(priority: .utility) {
                CLLocationManager.locationServicesEnabled()
            }.value
            guard let self else { return }
            self.locationServicesEnabled = isEnabled
            self.updateActivitySession()
        }
    }
}

extension BackgroundGenerationKeepAliveManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            let locationServicesEnabled = await Task.detached(priority: .utility) {
                CLLocationManager.locationServicesEnabled()
            }.value
            self?.applyAuthorizationStatus(
                status,
                locationServicesEnabled: locationServicesEnabled
            )
        }
    }
}
