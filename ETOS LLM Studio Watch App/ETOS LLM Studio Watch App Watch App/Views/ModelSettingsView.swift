// ============================================================================
// ModelSettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 模型设置视图
//
// 定义内容:
// - 提供一个表单用于编辑模型的模型名称与模型ID
// ============================================================================

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
                    .font(.caption)
            }
        }
        .navigationTitle("编辑模型信息")
    }
}
