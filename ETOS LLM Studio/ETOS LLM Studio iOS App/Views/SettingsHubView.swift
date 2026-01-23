import SwiftUI
import Shared

struct SettingsHubView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    
    var body: some View {
        List {
            Section {
                NavigationLink {
                    ConfigurableModelListView(providers: $viewModel.providers)
                } label: {
                    Label("模型行为配置", systemImage: "slider.horizontal.3")
                }
            }
        }
        .navigationTitle("数据与模型设置")
    }
}
