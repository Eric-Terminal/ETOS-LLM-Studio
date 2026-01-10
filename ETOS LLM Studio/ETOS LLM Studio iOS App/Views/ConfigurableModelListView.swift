import SwiftUI
import Shared

struct ConfigurableModelListView: View {
    @Binding var providers: [Provider]
    
    var body: some View {
        List {
            ForEach($providers) { $provider in
                if !provider.models.isEmpty {
                    Section(header: Text(provider.name)) {
                        ForEach($provider.models) { $model in
                            NavigationLink {
                                ModelBehaviorSettingsView(model: $model) {
                                    ConfigLoader.saveProvider(provider)
                                    ChatService.shared.reloadProviders()
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.displayName)
                                    Text(model.modelName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("模型行为配置")
    }
}
