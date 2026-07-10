// ============================================================================
// DisplaySettingsAnimationSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 iOS 聊天动画的二级设置视图。
// ============================================================================

import SwiftUI
import ETOSCore

struct ChatAnimationSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared

    var body: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("弹性滚动", comment: ""), isOn: $appConfig.chatScrollAnimationEnabled)

                if appConfig.chatScrollAnimationEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("位移幅度 %.0f pt", comment: ""), appConfig.chatScrollAnimationOffset))
                        Slider(value: $appConfig.chatScrollAnimationOffset, in: 4...60, step: 2)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("弹簧响应 %.2f s", comment: ""), appConfig.chatScrollAnimationSpringResponse))
                        Slider(value: $appConfig.chatScrollAnimationSpringResponse, in: 0.15...1.0, step: 0.05)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("弹簧阻尼 %.2f", comment: ""), appConfig.chatScrollAnimationSpringDamping))
                        Slider(value: $appConfig.chatScrollAnimationSpringDamping, in: 0.10...0.95, step: 0.05)
                    }

                    Button(NSLocalizedString("恢复默认参数", comment: "")) {
                        appConfig.chatScrollAnimationSpringResponse = 0.55
                        appConfig.chatScrollAnimationSpringDamping = 0.52
                        appConfig.chatScrollAnimationOffset = 32
                    }
                    .foregroundStyle(.secondary)
                }

                Toggle(NSLocalizedString("发送入场动画", comment: ""), isOn: $appConfig.chatSendAnimationEnabled)

                if appConfig.chatSendAnimationEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("飞入速度 %.2f s", comment: ""), appConfig.chatSendAnimationSpringResponse))
                        Slider(value: $appConfig.chatSendAnimationSpringResponse, in: 0.20...0.80, step: 0.05)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: NSLocalizedString("落点回弹 %.2f", comment: ""), appConfig.chatSendAnimationSpringDamping))
                        Slider(value: $appConfig.chatSendAnimationSpringDamping, in: 0.40...1.0, step: 0.05)
                    }

                    Button(NSLocalizedString("恢复发送动画默认", comment: "")) {
                        appConfig.chatSendAnimationSpringResponse = 0.45
                        appConfig.chatSendAnimationSpringDamping = 0.6
                    }
                    .foregroundStyle(.secondary)
                }
            } footer: {
                Text(NSLocalizedString("弹性滚动让气泡在滑动时产生交错回弹的波浪感。位移幅度越大弹跳越明显；弹簧响应越大惯性越强；阻尼越低回弹越剧烈。发送入场动画让气泡从输入框变形飞入消息位置：飞入速度越小越快，落点回弹越低晃动越明显。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("聊天动画", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}
