// ============================================================================
// GuideSettingsView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 集中说明页面向导的数据边界，并配置浮动入口与模型线路。
// ============================================================================

import SwiftUI
import ETOSCore

struct GuideSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @StateObject private var router = GuideModelRouter()
    @State private var isShowingDetails = false

    var body: some View {
        Form {
            Section {
                introductionCard
            }

            Section {
                Toggle(
                    NSLocalizedString("在设置页面显示向导", comment: "向导浮动入口开关"),
                    isOn: $appConfig.guideOverlayEnabled
                )
            } footer: {
                Text(NSLocalizedString("开启后，进入设置及已接入的配置页面时会显示可拖动的向导入口。", comment: "向导浮动入口说明"))
            }

            Section(NSLocalizedString("回答使用的模型", comment: "向导模型线路分组")) {
                routeRow(
                    title: NSLocalizedString("内置免费向导", comment: "内置向导线路名称"),
                    detail: NSLocalizedString("始终可用，不依赖你的模型配置", comment: "内置向导线路说明"),
                    selected: appConfig.guidePreferredRoute == GuideRoute.builtIn.rawValue
                ) {
                    appConfig.guidePreferredRoute = GuideRoute.builtIn.rawValue
                }

                ForEach(router.availableUserModels, id: \.id) { model in
                    routeRow(
                        title: model.model.displayName,
                        detail: model.provider.name,
                        selected: appConfig.guidePreferredRoute == GuideRoute.userModel.rawValue &&
                            appConfig.guidePreferredModelIdentifier == model.id
                    ) {
                        appConfig.guidePreferredModelIdentifier = model.id
                        appConfig.guidePreferredRoute = GuideRoute.userModel.rawValue
                    }
                }

                if router.availableUserModels.isEmpty {
                    Text(NSLocalizedString("没有已启用且支持工具调用的云端聊天模型。仍可继续使用内置免费向导。", comment: "向导无用户模型说明"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("页面向导", comment: "向导设置标题"))
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: "guide-settings",
                title: NSLocalizedString("页面向导设置", comment: "向导设置页面上下文标题"),
                documents: [GuideDocumentReference(id: "guide-overview", title: "Guide Overview")]
            ),
            snapshot: {
                GuidePageSnapshot(fields: [
                    "overlay_enabled": GuideSnapshotField(
                        label: NSLocalizedString("显示向导", comment: "向导快照字段"),
                        value: .bool(appConfig.guideOverlayEnabled)
                    ),
                    "route": GuideSnapshotField(
                        label: NSLocalizedString("模型线路", comment: "向导快照字段"),
                        value: .string(appConfig.guidePreferredRoute)
                    )
                ])
            }
        )
    }

    private var introductionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(NSLocalizedString("向导会看到什么", comment: "向导介绍卡标题"), systemImage: "eye")
                .font(.headline)
            Text(NSLocalizedString("当前页面会明确提供页面名称、相关文档和经过筛选的配置快照。密钥、密码与令牌只显示为已隐藏。", comment: "向导介绍卡摘要"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(NSLocalizedString("进一步了解…", comment: "向导介绍卡详情按钮")) {
                isShowingDetails = true
            }
            .buttonStyle(.plain)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isShowingDetails) {
            NavigationStack {
                ScrollView {
                    Text(NSLocalizedString("页面向导只读取每个页面主动声明的字段，不会截取屏幕、遍历辅助功能树或导出数据库。现有 API Key、密码和令牌不会发送给模型，但你可以在原生安全输入框中填写新值。向导提出的设置修改会先显示原生预览，只有你确认后才执行。对话、工具状态和撤销记录只保存在内存中，清空上下文或结束 App 进程后不会保留。默认先查内置文档；文档不足时才按当前构建的完整 Commit 读取公开源码。", comment: "向导介绍卡详情"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString("页面向导与隐私", comment: "向导介绍详情标题"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func routeRow(
        title: String,
        detail: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
