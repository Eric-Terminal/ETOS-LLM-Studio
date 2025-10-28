import SwiftUI
import Shared

struct ModelSettingsView: View {
    @Binding var model: Model
    
    var body: some View {
        Form {
            Section("基础信息") {
                TextField("显示名称", text: $model.displayName)
                TextField("技术名称", text: $model.modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
            }
        }
        .navigationTitle("模型信息")
    }
}
