
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
                        dismissAfterSave: false,
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
    }

    private func updateProvider(_ updatedProvider: Provider) {
        guard provider != updatedProvider else { return }
        provider = updatedProvider
        providerRevision += 1
    }
}
