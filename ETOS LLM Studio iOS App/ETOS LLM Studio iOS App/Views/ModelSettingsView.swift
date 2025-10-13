// ============================================================================
// ModelSettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 模型设置视图
//
// 定义内容:
// - 提供一个表单用于编辑模型的显示名称和技术名称
// ============================================================================

import SwiftUI
import Shared

struct ModelSettingsView: View {
    @Binding var model: Model
    
    var body: some View {
        Form {
            Section(header: Text("基础信息"), footer: Text("技术名称是模型在API中被调用的实际名称。显示名称是您在App中看到的别名。")) {
                TextField("显示名称", text: $model.displayName)
                TextField("技术名称", text: $model.modelName)
                    .font(.caption)
            }
        }
        .navigationTitle("编辑模型信息")
    }
}