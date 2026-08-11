// ============================================================================
// BackgroundGenerationSettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// 管理回复生成期间的定位后台活动、音频保活与权限状态。
// ============================================================================

import CoreLocation
import ETOSCore
import SwiftUI

struct BackgroundGenerationSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var keepAliveManager = BackgroundGenerationKeepAliveManager.shared
    @ObservedObject private var audioKeepAliveManager = BackgroundGenerationAudioKeepAliveManager.shared
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
                    NSLocalizedString("音频保活", comment: "后台生成音频保活开关"),
                    isOn: audioKeepAliveBinding
                )
                if appConfig.backgroundGenerationAudioKeepAliveEnabled {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(NSLocalizedString("等待音量", comment: "后台生成等待音量标题"))
                            Spacer()
                            Text(
                                appConfig.backgroundGenerationAudioKeepAliveVolume,
                                format: .percent.precision(.fractionLength(0))
                            )
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: audioVolumeBinding,
                            in: BackgroundGenerationAudioKeepAliveSettings.minimumVolume
                                ... BackgroundGenerationAudioKeepAliveSettings.maximumVolume,
                            step: 0.05
                        )
                    }

                    Button {
                        audioKeepAliveManager.togglePreview()
                    } label: {
                        Label(
                            audioKeepAliveManager.isPreviewing
                                ? NSLocalizedString("停止试听", comment: "停止试听等待音按钮")
                                : NSLocalizedString("试听等待音", comment: "试听后台生成等待音按钮"),
                            systemImage: audioKeepAliveManager.isPreviewing
                                ? "stop.circle"
                                : "play.circle"
                        )
                    }
                    .disabled(audioKeepAliveManager.isGenerationActive || ttsManager.isSpeaking)
                }
            } header: {
                Text(NSLocalizedString("保活方式", comment: "后台生成保活方式分组"))
            } footer: {
                Text(NSLocalizedString(
                    "两种方式可单独开启，也可组合使用。",
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
                    title: NSLocalizedString("音频保活", comment: "后台生成音频保活状态标题"),
                    value: audioKeepAliveStatusText,
                    color: audioKeepAliveStatusColor
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
                    "后台能力受系统调度影响，并会增加耗电。",
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
        .onDisappear {
            audioKeepAliveManager.stopPreview()
        }
    }

    private var keepAliveBinding: Binding<Bool> {
        Binding(
            get: { appConfig.backgroundGenerationKeepAliveEnabled },
            set: { keepAliveManager.setFeatureEnabled($0) }
        )
    }

    private var audioKeepAliveBinding: Binding<Bool> {
        Binding(
            get: { appConfig.backgroundGenerationAudioKeepAliveEnabled },
            set: { audioKeepAliveManager.setFeatureEnabled($0) }
        )
    }

    private var audioVolumeBinding: Binding<Double> {
        Binding(
            get: { appConfig.backgroundGenerationAudioKeepAliveVolume },
            set: { audioKeepAliveManager.setVolume($0) }
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

    private var audioKeepAliveStatusText: String {
        guard appConfig.backgroundGenerationAudioKeepAliveEnabled else {
            return NSLocalizedString("已关闭", comment: "音频保活关闭状态")
        }
        if audioKeepAliveManager.hasPlaybackError {
            return NSLocalizedString("等待音播放失败", comment: "音频保活播放失败状态")
        }
        if audioKeepAliveManager.isPlaying {
            return NSLocalizedString("正在播放等待音", comment: "音频保活运行中状态")
        }
        if audioKeepAliveManager.isPreparing {
            return NSLocalizedString("正在准备等待音", comment: "音频保活准备状态")
        }
        if audioKeepAliveManager.isGenerationActive, ttsManager.isSpeaking {
            return NSLocalizedString("朗读期间已暂停", comment: "音频保活为朗读暂停状态")
        }
        return NSLocalizedString("等待回复任务", comment: "音频保活等待任务状态")
    }

    private var audioKeepAliveStatusColor: Color {
        if audioKeepAliveManager.hasPlaybackError {
            return .orange
        }
        return audioKeepAliveManager.isPlaying ? .green : .secondary
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
