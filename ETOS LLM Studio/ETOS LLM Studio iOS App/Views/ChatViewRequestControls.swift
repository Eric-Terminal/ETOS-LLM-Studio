// ============================================================================
// ChatViewRequestControls.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 中模型请求体控制项的详情面板与覆盖层面板。
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

struct OverlayRequestControlDetailPanel: View {
    @Environment(\.colorScheme) private var colorScheme

    let runnableModel: RunnableModel
    let control: ModelRequestBodyControl
    @State private var state: ModelRequestBodyControlState

    init(runnableModel: RunnableModel, control: ModelRequestBodyControl) {
        self.runnableModel = runnableModel
        self.control = control
        _state = State(initialValue: runnableModel.requestBodyControlState)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(control.title)
                    .etFont(.system(size: 15, weight: .semibold))
                    .foregroundColor(TelegramColors.navBarText)
                    .padding(.horizontal, 2)

                switch control.kind {
                case .toggle:
                    Toggle(isOn: toggleBinding(for: control)) {
                        Text(control.title)
                            .etFont(.system(size: 14, weight: .medium))
                            .foregroundColor(TelegramColors.navBarText)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(rowBackground)
                case .optionGroup:
                    if control.options.isEmpty {
                        Text(NSLocalizedString("这个控制还没有选项。", comment: ""))
                            .etFont(.system(size: 12))
                            .foregroundColor(TelegramColors.navBarSubtitle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(control.options) { option in
                            Button {
                                state.selectedOptionIDsByControlID[control.id] = option.id
                                saveState()
                            } label: {
                                HStack(spacing: 8) {
                                    Text(option.title)
                                        .etFont(.system(size: 14, weight: .medium))
                                        .foregroundColor(TelegramColors.navBarText)

                                    Spacer()

                                    Image(systemName: selectedOptionID(for: control) == option.id ? "checkmark.circle.fill" : "circle")
                                        .etFont(.system(size: 14, weight: .semibold))
                                        .foregroundColor(
                                            selectedOptionID(for: control) == option.id
                                                ? TelegramColors.sendButtonColor
                                                : TelegramColors.navBarSubtitle.opacity(0.5)
                                        )
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(rowBackground)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(colorScheme == .dark ? Color.black.opacity(0.2) : Color.black.opacity(0.05))
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
