
// ============================================================================
// ProviderActionsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 提供商操作视图
//
// 定义内容:
// - 提供单个提供商的模型配置与提供商配置入口
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct ProviderActionsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    
    @State private var provider: Provider
    @State private var providerRevision = 0
    private var isLocalProvider: Bool {
        LocalModelProviderBridge.isLocalProvider(provider)
    }

    init(provider: Provider) {
        _provider = State(initialValue: provider)
    }

    var body: some View {
        List {
            Section(NSLocalizedString("配置入口", comment: "")) {
                NavigationLink {
                    ProviderDetailView(
                        provider: provider,
                        allowsRemoteModelFetch: !isLocalProvider && provider.apiFormat.lowercased() != "anthropic",
                        allowsModelTesting: !isLocalProvider,
                        allowsManualModelAdd: !isLocalProvider
                    ) { updatedProvider in
                        updateProvider(updatedProvider)
                    }
                        .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("模型配置", comment: ""), systemImage: "square.stack.3d.up")
                }

                NavigationLink {
                    ProviderEditView(
                        provider: provider,
                        isNew: false,
                        showsCancelButton: false,
                        navigationTitleOverride: NSLocalizedString("提供商配置", comment: "")
                    ) { updatedProvider in
                        updateProvider(updatedProvider)
                    }
                    .id(providerRevision)
                    .environmentObject(viewModel)
                } label: {
                    Label(NSLocalizedString("提供商配置", comment: ""), systemImage: "slider.horizontal.3")
                }
            }
        }
        .navigationTitle(provider.name)
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: GuidePageID(rawValue: "watch-provider-actions-\(provider.id)"),
                title: provider.name,
                documents: [GuideDocumentReference(id: "provider-model-basics", title: "Provider and Model Basics")]
            ),
            snapshot: {
                GuidePageSnapshot(fields: [
                    "name": GuideSnapshotField(
                        label: NSLocalizedString("提供商名称", comment: "手表提供商入口向导快照字段"),
                        value: .string(provider.name),
                        access: .readOnly
                    ),
                    "base_url": GuideSnapshotField(
                        label: NSLocalizedString("API 地址", comment: "手表提供商入口向导快照字段"),
                        value: .string(provider.baseURL),
                        access: .readOnly
                    ),
                    "api_format": GuideSnapshotField(
                        label: NSLocalizedString("API 格式", comment: "手表提供商入口向导快照字段"),
                        value: .string(provider.apiFormat),
                        access: .readOnly
                    )
                ])
            }
        )
        .watchGuideEntry()
    }

    private func updateProvider(_ updatedProvider: Provider) {
        guard provider != updatedProvider else { return }
        provider = updatedProvider
        providerRevision += 1
    }
}
