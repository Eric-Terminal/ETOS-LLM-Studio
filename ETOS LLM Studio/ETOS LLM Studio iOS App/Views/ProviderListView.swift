import SwiftUI
import Foundation
import Shared

struct ProviderListView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var isAddingProvider = false
    @State private var providerToEdit: Provider?
    @State private var providerToDelete: Provider?
    @State private var showDeleteAlert = false
    
    var body: some View {
        List {
            ForEach(viewModel.providers) { provider in
                NavigationLink {
                    ProviderDetailView(provider: provider)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.name)
                        Text(provider.baseURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button {
                        providerToEdit = provider
                    } label: {
                        Label("编辑提供商", systemImage: "pencil")
                    }
                    
                    Button(role: .destructive) {
                        providerToDelete = provider
                        showDeleteAlert = true
                    } label: {
                        Label("删除提供商", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("提供商设置")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isAddingProvider = true
                } label: {
                    Label("添加提供商", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingProvider) {
            NavigationStack {
                ProviderEditView(
                    provider: Provider(name: "", baseURL: "", apiKeys: [""], apiFormat: "openai-compatible"),
                    isNew: true
                )
                .environmentObject(viewModel)
            }
        }
        .sheet(item: $providerToEdit) { provider in
            NavigationStack {
                ProviderEditView(provider: provider, isNew: false)
                    .environmentObject(viewModel)
            }
        }
        .alert("确认删除提供商", isPresented: $showDeleteAlert) {
            Button("删除", role: .destructive) {
                if let target = providerToDelete {
                    ConfigLoader.deleteProvider(target)
                    ChatService.shared.reloadProviders()
                }
                providerToDelete = nil
            }
            Button("取消", role: .cancel) {
                providerToDelete = nil
            }
        } message: {
            if let target = providerToDelete {
                Text(String(format: NSLocalizedString("删除“%@”后无法恢复。", comment: ""), target.name))
            } else {
                Text("此操作无法撤销。")
            }
        }
    }
}
