// ============================================================================
// ChatViewRequestControls.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 中模型请求体控制项的详情面板。
// ============================================================================

import SwiftUI
import Shared

struct ChatRequestBodyControlDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let runnableModel: RunnableModel
    let control: ModelRequestBodyControl
    @State private var state: ModelRequestBodyControlState

    init(runnableModel: RunnableModel, control: ModelRequestBodyControl) {
        self.runnableModel = runnableModel
        self.control = control
        _state = State(initialValue: runnableModel.requestBodyControlState)
    }

    var body: some View {
        List {
            switch control.kind {
            case .toggle:
                Toggle(isOn: toggleBinding(for: control)) {
                    Text(control.title)
                }
            case .optionGroup:
                if control.options.isEmpty {
                    Text(NSLocalizedString("这个控制还没有选项。", comment: ""))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(control.options) { option in
                        Button {
                            state.selectedOptionIDsByControlID[control.id] = option.id
                            saveState()
                        } label: {
                            HStack {
                                Text(option.title)
                                Spacer()
                                if selectedOptionID(for: control) == option.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(control.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("完成", comment: "")) {
                    dismiss()
                }
            }
        }
    }

    private func toggleBinding(for control: ModelRequestBodyControl) -> Binding<Bool> {
        Binding(
            get: { state.toggleValuesByControlID[control.id] ?? control.defaultIsActive },
            set: { newValue in
                state.toggleValuesByControlID[control.id] = newValue
                saveState()
            }
        )
    }

    private func selectedOptionID(for control: ModelRequestBodyControl) -> String {
        state.selectedOptionIDsByControlID[control.id]
            ?? control.defaultOptionID
            ?? control.options.first?.id
            ?? ""
    }

    private func saveState() {
        state = ModelRequestBodyControlCompiler.normalized(state, for: runnableModel.model.requestBodyControls)
        runnableModel.saveRequestBodyControlState(state)
    }
}
