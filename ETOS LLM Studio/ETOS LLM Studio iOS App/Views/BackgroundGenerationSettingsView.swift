// ============================================================================
// BackgroundGenerationSettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// 管理回复生成期间的定位后台活动、后台朗读与权限状态。
// ============================================================================

import CoreLocation
import ETOSCore
import SwiftUI

struct BackgroundGenerationSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var keepAliveManager = BackgroundGenerationKeepAliveManager.shared
    @ObservedObject private var speechCoordinator = BackgroundReplySpeechCoordinator.shared
    @ObservedObject private var ttsManager = TTSManager.shared
    @State private var isShowingIntroDetails = false

    var body: some View {
        Form {
            Section {
                settingsIntroCard
            }

            Section {
                Toggle(
                    NSLocalizedString("位置追踪", comment: "后台生成位置追踪开关"),
                    isOn: keepAliveBinding
                )
                Toggle(
                    NSLocalizedString("后台朗读", comment: "后台生成朗读开关"),
                    isOn: speechBinding
                )
            } header: {
                Text(NSLocalizedString("保活方式", comment: "后台生成保活方式分组"))
            } footer: {
                Text(NSLocalizedString(
                    "两种方式均默认关闭，可单独使用。后台朗读会用系统语音读出已生成的完整句子，不调用云端 TTS；有声音播放时才能延长后台运行。",
                    comment: "后台生成保活方式说明"
                ))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                statusRow(
                    title: NSLocalizedString("位置活动", comment: "后台生成位置活动状态标题"),
                    value: runningStatusText,
                    color: runningStatusColor
                )

                statusRow(
                    title: NSLocalizedString("后台朗读", comment: "后台生成朗读状态标题"),
                    value: speechStatusText,
                    color: speechStatusColor
                )

                statusRow(
                    title: NSLocalizedString("定位权限", comment: "后台持续生成定位权限标题"),
                    value: authorizationStatusText,
                    color: authorizationStatusColor
                )

                if shouldShowAuthorizationRequestButton {
                    Button(NSLocalizedString("请求定位权限", comment: "请求后台持续生成定位权限按钮")) {
                        keepAliveManager.requestAuthorizationIfNeeded()
                    }
                } else if shouldShowSystemSettingsButton {
                    Button(NSLocalizedString("打开系统设置", comment: "打开定位系统设置按钮")) {
                        keepAliveManager.openSystemSettings()
                    }
                }
            } header: {
                Text(NSLocalizedString("状态", comment: "后台持续生成状态分组"))
            } footer: {
                Text(NSLocalizedString(
                    "位置追踪运行时，iOS 会显示蓝色定位指示器；ETOS 不读取、保存或上传位置坐标。后台朗读只在已有完整句子后生效，首字返回前仍可能受系统调度影响。两种方式都会增加耗电。",
                    comment: "后台持续生成状态说明"
                ))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("后台生成", comment: "后台生成设置页标题"))
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

    private var settingsIntroCard: some View {
        VStack(alignment: .leading) {
            Text(NSLocalizedString("后台生成", comment: "后台生成介绍标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString(
                "切换到其他 App 时，尽量让正在进行的 AI 回复继续接收。",
                comment: "后台生成介绍摘要"
            ))
            .etFont(.subheadline)
            .foregroundStyle(.secondary)
            Button(NSLocalizedString("进一步了解…", comment: "后台生成介绍展开按钮")) {
                isShowingIntroDetails = true
            }
            .buttonStyle(.plain)
            .etFont(.footnote.weight(.medium))
            .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: $isShowingIntroDetails) {
            NavigationStack {
                ScrollView {
                    Text(NSLocalizedString("后台生成说明正文", comment: "后台生成详细说明"))
                        .etFont(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString("后台生成", comment: "后台生成详情页标题"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func statusRow(title: String, value: String, color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
    }

    private var runningStatusText: String {
        guard appConfig.backgroundGenerationKeepAliveEnabled else {
            return NSLocalizedString("已关闭", comment: "后台持续生成关闭状态")
        }
        guard keepAliveManager.locationServicesEnabled else {
            return NSLocalizedString("系统定位已关闭", comment: "系统定位服务关闭状态")
        }
        guard BackgroundGenerationKeepAlivePolicy.hasUsableAuthorization(keepAliveManager.authorizationStatus) else {
            return NSLocalizedString("需要定位权限", comment: "后台持续生成缺少权限状态")
        }
        if keepAliveManager.isActivitySessionActive {
            return NSLocalizedString("正在保护回复连接", comment: "后台持续生成运行中状态")
        }
        return NSLocalizedString("等待回复任务", comment: "后台持续生成等待状态")
    }

    private var runningStatusColor: Color {
        if keepAliveManager.isActivitySessionActive {
            return .green
        }
        if appConfig.backgroundGenerationKeepAliveEnabled,
           (!keepAliveManager.locationServicesEnabled
            || !BackgroundGenerationKeepAlivePolicy.hasUsableAuthorization(keepAliveManager.authorizationStatus)) {
            return .orange
        }
        return .secondary
    }

    private var speechStatusText: String {
        guard appConfig.backgroundGenerationSpeechEnabled else {
            return NSLocalizedString("已关闭", comment: "后台朗读关闭状态")
        }
        if isBackgroundReplySpeaking {
            return NSLocalizedString("正在朗读回复", comment: "后台朗读运行中状态")
        }
        if !speechCoordinator.activeSessionIDs.isEmpty {
            return NSLocalizedString("等待完整句子", comment: "后台朗读等待句子状态")
        }
        return NSLocalizedString("等待回复任务", comment: "后台朗读等待任务状态")
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
        guard keepAliveManager.locationServicesEnabled else {
            return NSLocalizedString("系统定位已关闭", comment: "系统定位服务关闭状态")
        }
        switch keepAliveManager.authorizationStatus {
        case .authorizedWhenInUse:
            return NSLocalizedString("使用 App 期间", comment: "定位使用期间权限状态")
        case .authorizedAlways:
            return NSLocalizedString("始终", comment: "定位始终权限状态")
        case .notDetermined:
            return NSLocalizedString("未决定", comment: "定位权限未决定状态")
        case .denied:
            return NSLocalizedString("已拒绝", comment: "定位权限拒绝状态")
        case .restricted:
            return NSLocalizedString("受限", comment: "定位权限受限状态")
        @unknown default:
            return NSLocalizedString("未知", comment: "定位权限未知状态")
        }
    }

    private var authorizationStatusColor: Color {
        guard keepAliveManager.locationServicesEnabled else { return .orange }
        return BackgroundGenerationKeepAlivePolicy.hasUsableAuthorization(keepAliveManager.authorizationStatus)
            ? .green
            : .secondary
    }

    private var shouldShowAuthorizationRequestButton: Bool {
        appConfig.backgroundGenerationKeepAliveEnabled
            && keepAliveManager.locationServicesEnabled
            && keepAliveManager.authorizationStatus == .notDetermined
    }

    private var shouldShowSystemSettingsButton: Bool {
        guard appConfig.backgroundGenerationKeepAliveEnabled else { return false }
        guard keepAliveManager.locationServicesEnabled else { return true }
        return keepAliveManager.authorizationStatus == .denied
            || keepAliveManager.authorizationStatus == .restricted
    }
}
