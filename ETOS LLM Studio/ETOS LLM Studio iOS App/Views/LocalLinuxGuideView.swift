// ============================================================================
// LocalLinuxGuideView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本地 Linux 首页介绍卡与结构化使用指南。
// ============================================================================

import ETOSCore
import SwiftUI

struct LocalLinuxGuideCard: View {
    @State private var isShowingGuide = false

    var body: some View {
        VStack(alignment: .leading) {
            Text(NSLocalizedString("本地 Linux 使用指南", comment: "Local Linux guide card title"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString("从首次启用到终端、Agent、本地 MCP、文件管理与系统恢复。", comment: "Local Linux guide card summary"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button(NSLocalizedString("进一步了解…", comment: "Local Linux guide card action")) {
                isShowingGuide = true
            }
            .buttonStyle(.plain)
            .etFont(.footnote.weight(.medium))
            .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: $isShowingGuide) {
            NavigationStack {
                LocalLinuxGuideView()
            }
        }
    }
}

private struct LocalLinuxGuideView: View {
    var body: some View {
        List {
            guideSection(
                title: "快速开始",
                body: "本地 Linux 指南：快速开始"
            )
            guideSection(
                title: "Chat、Agent 与终端",
                body: "本地 Linux 指南：Chat、Agent 与终端"
            )
            guideSection(
                title: "默认终端 Shell",
                body: "只列出当前 Linux 系统中已安装的 Shell。新终端会以登录 Shell 启动；Agent 的脚本命令仍固定使用 /bin/sh。"
            )
            guideSection(
                title: "软件与本地 MCP",
                body: "本地 Linux 指南：软件与本地 MCP"
            )
            guideSection(
                title: "文件、工作区与挂载",
                body: "本地 Linux 指南：文件、工作区与挂载"
            )
            guideSection(
                title: "环境变量与安全策略",
                body: "本地 Linux 指南：环境变量与安全策略"
            )
            guideSection(
                title: "资源与并发",
                body: "本地 Linux 指南：资源与并发"
            )
            guideSection(
                title: "诊断、反馈与重置",
                body: "本地 Linux 指南：诊断、反馈与重置"
            )
        }
        .navigationTitle(NSLocalizedString("本地 Linux 使用指南", comment: "Local Linux guide title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func guideSection(title: String, body: String) -> some View {
        Section(NSLocalizedString(title, comment: "Local Linux guide section title")) {
            Text(NSLocalizedString(body, comment: "Local Linux guide section body"))
                .etFont(.body)
                .textSelection(.enabled)
        }
    }
}
