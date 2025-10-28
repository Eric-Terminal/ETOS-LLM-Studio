import SwiftUI
import Shared

struct SettingsHubView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    var body: some View {
        List {
            Section {
                NavigationLink {
                    ProviderListView().environmentObject(viewModel)
                } label: {
                    Label("提供商与模型管理", systemImage: "list.bullet.rectangle.portrait")
                }
                
                NavigationLink {
                    ConfigurableModelListView(providers: $viewModel.providers)
                } label: {
                    Label("模型行为配置", systemImage: "slider.horizontal.3")
                }
                
                NavigationLink {
                    MemorySettingsView().environmentObject(viewModel)
                } label: {
                    Label("记忆库管理", systemImage: "brain.head.profile")
                }
            }
        }
        .navigationTitle("数据与模型设置")
    }
}
