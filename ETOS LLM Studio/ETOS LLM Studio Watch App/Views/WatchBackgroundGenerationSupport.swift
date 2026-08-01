// ============================================================================
// WatchBackgroundGenerationSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 管理 watchOS 回复生成期间的定位后台活动、后台朗读及其设置行。
// 本功能不请求位置更新，也不读取、保存或上传位置坐标。
// ============================================================================

import Combine
@preconcurrency import CoreLocation
import ETOSCore
import SwiftUI

@MainActor
final class WatchBackgroundGenerationKeepAliveManager: NSObject, ObservableObject {
    static let shared = WatchBackgroundGenerationKeepAliveManager()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var isActivitySessionActive = false

    private let locationManager: CLLocationManager
    private var backgroundActivitySession: CLBackgroundActivitySession?
    private var hasActiveGeneration = false

    private override init() {
        let locationManager = CLLocationManager()
        self.locationManager = locationManager
        authorizationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
    }

    func setFeatureEnabled(_ enabled: Bool) {
        AppConfigStore.shared.backgroundGenerationKeepAliveEnabled = enabled
        if enabled {
            requestAuthorizationIfNeeded()
        }
        updateActivitySession()
    }

    func setGenerationActive(_ isActive: Bool) {
        hasActiveGeneration = isActive
        updateActivitySession()
    }

    func refreshStatus() {
        authorizationStatus = locationManager.authorizationStatus
        updateActivitySession()
    }

    func requestAuthorizationIfNeeded() {
        refreshStatus()
        guard authorizationStatus == .notDetermined else { return }
        locationManager.requestWhenInUseAuthorization()
    }

    private func updateActivitySession() {
        let hasAuthorization = authorizationStatus == .authorizedWhenInUse
            || authorizationStatus == .authorizedAlways
        let shouldActivate = AppConfigStore.shared.backgroundGenerationKeepAliveEnabled
            && hasActiveGeneration
            && hasAuthorization

        if shouldActivate {
            guard backgroundActivitySession == nil else { return }
            // 必须持续持有此对象，否则系统会立即结束后台活动。
            backgroundActivitySession = CLBackgroundActivitySession()
            isActivitySessionActive = true
        } else {
            backgroundActivitySession?.invalidate()
            backgroundActivitySession = nil
            isActivitySessionActive = false
        }
    }

    private func applyAuthorizationStatus(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        updateActivitySession()
    }
}

extension WatchBackgroundGenerationKeepAliveManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.applyAuthorizationStatus(status)
        }
    }
}

struct WatchBackgroundGenerationSettingsRows: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var keepAliveManager = WatchBackgroundGenerationKeepAliveManager.shared
    @ObservedObject private var speechCoordinator = BackgroundReplySpeechCoordinator.shared
    @ObservedObject private var ttsManager = TTSManager.shared

    var body: some View {
        Section {
            Toggle(
                NSLocalizedString("位置追踪", comment: "watchOS 后台生成位置追踪开关"),
                isOn: keepAliveBinding
            )

            Toggle(
                NSLocalizedString("后台朗读", comment: "watchOS 后台生成朗读开关"),
                isOn: speechBinding
            )

            statusRow(
                title: NSLocalizedString("位置活动", comment: "watchOS 后台生成位置活动状态"),
                value: runningStatusText,
                color: runningStatusColor
            )

            statusRow(
                title: NSLocalizedString("后台朗读", comment: "watchOS 后台生成朗读状态"),
                value: speechStatusText,
                color: speechStatusColor
            )

            statusRow(
                title: NSLocalizedString("定位权限", comment: "watchOS 后台持续生成定位权限"),
                value: authorizationStatusText,
                color: hasUsableAuthorization ? .green : .secondary
            )

            if appConfig.backgroundGenerationKeepAliveEnabled,
               keepAliveManager.authorizationStatus == .notDetermined {
                Button(NSLocalizedString("请求定位权限", comment: "watchOS 请求后台持续生成定位权限")) {
                    keepAliveManager.requestAuthorizationIfNeeded()
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(NSLocalizedString("后台生成", comment: "watchOS 后台生成设置分组"))
        } footer: {
            Text(NSLocalizedString(
                "两种方式均默认关闭，可单独使用。后台朗读使用系统语音读出完整句子；位置活动不读取、保存或上传坐标。朗读开始前仍可能受系统调度影响。",
                comment: "watchOS 后台持续生成说明"
            ))
            .etFont(.footnote)
            .foregroundStyle(.secondary)
        }
        .onAppear {
            keepAliveManager.refreshStatus()
        }
    }

    private var keepAliveBinding: Binding<Bool> {
        Binding(
            get: { appConfig.backgroundGenerationKeepAliveEnabled },
            set: { keepAliveManager.setFeatureEnabled($0) }
        )
    }

    private var speechBinding: Binding<Bool> {
        Binding(
            get: { appConfig.backgroundGenerationSpeechEnabled },
            set: { speechCoordinator.setFeatureEnabled($0) }
        )
    }

    private func statusRow(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading) {
            Text(title)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .etFont(.footnote)
                .foregroundStyle(color)
        }
    }

    private var hasUsableAuthorization: Bool {
        keepAliveManager.authorizationStatus == .authorizedWhenInUse
            || keepAliveManager.authorizationStatus == .authorizedAlways
    }

    private var runningStatusText: String {
        guard appConfig.backgroundGenerationKeepAliveEnabled else {
            return NSLocalizedString("已关闭", comment: "watchOS 后台持续生成关闭状态")
        }
        guard hasUsableAuthorization else {
            return NSLocalizedString("需要定位权限", comment: "watchOS 后台持续生成缺少权限状态")
        }
        return keepAliveManager.isActivitySessionActive
            ? NSLocalizedString("正在保护回复连接", comment: "watchOS 后台持续生成运行中状态")
            : NSLocalizedString("等待回复任务", comment: "watchOS 后台持续生成等待状态")
    }

    private var runningStatusColor: Color {
        if keepAliveManager.isActivitySessionActive {
            return .green
        }
        return appConfig.backgroundGenerationKeepAliveEnabled && !hasUsableAuthorization
            ? .orange
            : .secondary
    }

    private var speechStatusText: String {
        guard appConfig.backgroundGenerationSpeechEnabled else {
            return NSLocalizedString("已关闭", comment: "watchOS 后台朗读关闭状态")
        }
        if isBackgroundReplySpeaking {
            return NSLocalizedString("正在朗读回复", comment: "watchOS 后台朗读运行中状态")
        }
        if !speechCoordinator.activeSessionIDs.isEmpty {
            return NSLocalizedString("等待完整句子", comment: "watchOS 后台朗读等待句子状态")
        }
        return NSLocalizedString("等待回复任务", comment: "watchOS 后台朗读等待任务状态")
    }

    private var speechStatusColor: Color {
        isBackgroundReplySpeaking ? .green : .secondary
    }

    private var isBackgroundReplySpeaking: Bool {
        guard ttsManager.isSpeaking,
              let messageID = ttsManager.currentSpeakingMessageID else { return false }
        return speechCoordinator.hasHandled(messageID: messageID)
    }

    private var authorizationStatusText: String {
        switch keepAliveManager.authorizationStatus {
        case .authorizedWhenInUse:
            return NSLocalizedString("使用 App 期间", comment: "watchOS 定位使用期间权限")
        case .authorizedAlways:
            return NSLocalizedString("始终", comment: "watchOS 定位始终权限")
        case .notDetermined:
            return NSLocalizedString("未决定", comment: "watchOS 定位权限未决定")
        case .denied:
            return NSLocalizedString("已拒绝", comment: "watchOS 定位权限已拒绝")
        case .restricted:
            return NSLocalizedString("受限", comment: "watchOS 定位权限受限")
        @unknown default:
            return NSLocalizedString("未知", comment: "watchOS 定位权限未知")
        }
    }
}
