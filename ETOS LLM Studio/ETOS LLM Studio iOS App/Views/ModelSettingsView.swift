import SwiftUI
import Shared

struct ModelSettingsView: View {
    @Binding var model: Model
    
    var body: some View {
        Form {
            Section(
                header: Text("基础信息"),
                footer: Text("模型ID是 API 调用时使用的真实标识，模型名称是 App 内展示给用户的别名。")
            ) {
                TextField("模型名称", text: $model.displayName)
                TextField("模型ID", text: $model.modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
            }
        }
        .navigationTitle("模型信息")
    }
}
