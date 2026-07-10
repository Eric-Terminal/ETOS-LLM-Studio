// ============================================================================
// ChatViewModelPicker.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 的模型选择底部抽屉。
// ============================================================================

import SwiftUI
import ETOSCore
import UIKit

extension ChatView {
    var nativeModelPickerSheet: some View {
        NavigationStack {
            nativeModelPickerContent
            .navigationTitle(NSLocalizedString("选择模型", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismissModelPickerSheet()
                    }
                }
            }
        }
    }

    var nativeModelPickerContent: some View {
        List {
            if viewModel.activatedConversationModels.isEmpty {
                VStack(spacing: 6) {
                    Text(NSLocalizedString("暂无可用模型", comment: ""))
                        .etFont(.headline)
                    Text(NSLocalizedString("请先在设置中启用模型", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 28)
            } else {
                Section {
                    ForEach(topModelChoices, id: \.id) { runnable in
                        nativeModelPickerModelRow(runnable)
                    }
                } header: {
                    Text(NSLocalizedString("置顶模型", comment: ""))
                } footer: {
                    Text(NSLocalizedString("切换当前对话的模型", comment: ""))
                }

                if hasModelPickerRequestControls {
                    Section {
                        nativeModelPickerRequestControlRows
                    } header: {
                        Text(NSLocalizedString("请求控制", comment: ""))
                    } footer: {
                        Text(NSLocalizedString("开关与滑块可直接调整，其他选项组可进入详情选择。", comment: ""))
                    }
                }

                if hasMoreModelChoices {
                    Section {
                        NavigationLink {
                            nativeModelPickerAllModelsList
                        } label: {
                            Label(NSLocalizedString("更多模型", comment: ""), systemImage: "ellipsis")
                        }
                    }
                }
            }
        }
    }

    var nativeModelPickerAllModelsList: some View {
        List {
            Section {
                ForEach(viewModel.activatedConversationModels, id: \.id) { runnable in
                    nativeModelPickerModelRow(runnable)
                }
            } header: {
                Text(NSLocalizedString("模型", comment: ""))
            }
        }
        .navigationTitle(NSLocalizedString("更多模型", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    func nativeModelPickerModelRow(_ runnable: RunnableModel) -> some View {
        Button {
            viewModel.setSelectedModel(runnable)
            dismissModelPickerSheet()
        } label: {
            MarqueeTitleSubtitleSelectionRow(
                title: runnable.model.displayName,
                subtitle: "\(runnable.provider.name) · \(runnable.model.modelName)",
                isSelected: runnable.id == viewModel.selectedModel?.id,
                subtitleUIFont: .monospacedSystemFont(ofSize: 12, weight: .regular)
            )
        }
    }

    @ViewBuilder
    var nativeModelPickerRequestControlRows: some View {
        if let selectedModel = viewModel.selectedModel {
            ChatRequestBodyControlRows(
                runnableModel: selectedModel,
                controls: selectedModelRequestControls,
                onDone: dismissModelPickerSheet
            )
        }
    }

    var topModelChoices: [RunnableModel] {
        Array(viewModel.activatedConversationModels.prefix(3))
    }

    var hasMoreModelChoices: Bool {
        viewModel.activatedConversationModels.count > topModelChoices.count
    }

    var selectedModelRequestControls: [ModelRequestBodyControl] {
        viewModel.selectedModel?.model.requestBodyControls.filter(\.isEnabled) ?? []
    }

    var hasModelPickerRequestControls: Bool {
        !selectedModelRequestControls.isEmpty
    }
}

private struct ChatRequestBodyControlRows: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let runnableModel: RunnableModel
    let controls: [ModelRequestBodyControl]
    let onDone: () -> Void

    @State private var state: ModelRequestBodyControlState?
    @State private var pendingSaveTask: Task<Void, Never>?
    @State private var lastAnchorIndices: [String: Int] = [:]
    @State private var lastSliderPositions: [String: Double] = [:]
    @State private var sliderDescriptors: [String: ModelRequestBodyControlSliderDescriptor] = [:]

    var body: some View {
        ForEach(controls) { control in
            switch control.kind {
            case .toggle:
                Toggle(isOn: toggleBinding(for: control)) {
                    Text(control.title)
                }
                .disabled(state == nil)
            case .optionGroup:
                if let descriptor = sliderDescriptors[control.id] {
                    sliderRow(for: control, descriptor: descriptor)
                } else if control.isSliderEnabled, state == nil {
                    HStack {
                        Text(control.title)
                        Spacer()
                        ProgressView()
                    }
                } else {
                    NavigationLink {
                        ChatRequestBodyControlDetailView(
                            runnableModel: runnableModel,
                            control: control,
                            onDone: onDone
                        )
                    } label: {
                        Text(control.title)
                    }
                }
            }
        }
        .task(id: runnableModel.id) {
            await loadState()
        }
    }

    private func toggleBinding(for control: ModelRequestBodyControl) -> Binding<Bool> {
        Binding(
            get: {
                state?.toggleValuesByControlID[control.id] ?? control.defaultIsActive
            },
            set: { isActive in
                guard var updatedState = state else { return }
                updatedState.toggleValuesByControlID[control.id] = isActive
                state = updatedState
                enqueueToggleSave(isActive, controlID: control.id)
            }
        )
    }

    private func loadState() async {
        state = nil
        let modelKey = runnableModel.id
        let modelControls = runnableModel.model.requestBodyControls
        let loaded = await Task.detached(priority: .userInitiated) {
            let loadedState = ModelRequestBodyControlRuntimeStore.state(
                forModelKey: modelKey,
                controls: modelControls
            )
            let descriptors: [String: ModelRequestBodyControlSliderDescriptor] = Dictionary(
                uniqueKeysWithValues: modelControls.compactMap { control in
                    guard control.isSliderEnabled,
                          let descriptor = ModelRequestBodyControlSliderDescriptor(control: control) else {
                        return nil
                    }
                    return (control.id, descriptor)
                }
            )
            return (loadedState, descriptors)
        }.value
        guard !Task.isCancelled else { return }
        state = loaded.0
        sliderDescriptors = loaded.1
        lastAnchorIndices = Dictionary(uniqueKeysWithValues: loaded.1.map { controlID, descriptor in
            (controlID, descriptor.nearestAnchorIndex(at: descriptor.position(in: loaded.0)))
        })
        lastSliderPositions = Dictionary(uniqueKeysWithValues: loaded.1.map { controlID, descriptor in
            (controlID, descriptor.position(in: loaded.0))
        })
    }

    private func enqueueToggleSave(_ isActive: Bool, controlID: String) {
        let previousSaveTask = pendingSaveTask
        let modelKey = runnableModel.id
        let modelControls = runnableModel.model.requestBodyControls
        pendingSaveTask = Task(priority: .utility) {
            await previousSaveTask?.value
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                ModelRequestBodyControlRuntimeStore.saveToggleValue(
                    isActive,
                    forControlID: controlID,
                    forModelKey: modelKey,
                    controls: modelControls
                )
            }.value
        }
    }

    private func sliderRow(
        for control: ModelRequestBodyControl,
        descriptor: ModelRequestBodyControlSliderDescriptor
    ) -> some View {
        let position = descriptor.position(in: state ?? ModelRequestBodyControlState())
        let displayValue = descriptor.displayValue(at: position)
        let palette = sliderPalette(for: control)

        return VStack {
            HStack {
                Text(control.title)
                    .lineLimit(1)
                Spacer()
                Text(displayValue)
                    .etFont(.footnote.monospaced())
                    .foregroundStyle(palette.color(at: position))
                    .lineLimit(1)
            }

            RequestBodyGradientSlider(
                value: sliderBinding(for: control, descriptor: descriptor),
                palette: palette,
                anchorCount: descriptor.optionCount,
                adjustmentStep: descriptor.crownStep,
                accessibilityLabel: control.title,
                accessibilityValue: displayValue,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        settleAndSaveSlider(for: control, descriptor: descriptor)
                    }
                }
            )
        }
        .disabled(state == nil)
    }

    private func sliderPalette(for control: ModelRequestBodyControl) -> RequestBodySliderPalette {
        control.options.contains { $0.payload.keys.contains("temperature") }
            ? .temperature
            : .structured
    }

    private func sliderBinding(
        for control: ModelRequestBodyControl,
        descriptor: ModelRequestBodyControlSliderDescriptor
    ) -> Binding<Double> {
        Binding(
            get: {
                descriptor.position(in: state ?? ModelRequestBodyControlState())
            },
            set: { position in
                updateSliderPosition(
                    position,
                    for: control,
                    descriptor: descriptor,
                    providesFeedback: true
                )
            }
        )
    }

    private func updateSliderPosition(
        _ position: Double,
        for control: ModelRequestBodyControl,
        descriptor: ModelRequestBodyControlSliderDescriptor,
        providesFeedback: Bool
    ) {
        guard var updatedState = state else { return }
        let normalizedPosition = descriptor.normalized(position)
        updatedState.sliderPositionsByControlID[control.id] = normalizedPosition
        updatedState.selectedOptionIDsByControlID[control.id] = descriptor.nearestOptionID(
            at: normalizedPosition
        )
        state = updatedState

        let anchorIndex = descriptor.nearestAnchorIndex(at: normalizedPosition)
        let previousPosition = lastSliderPositions[control.id] ?? normalizedPosition
        let shouldProvideFeedback = switch descriptor.mode {
        case .discrete:
            lastAnchorIndices[control.id] != anchorIndex
        case .continuousNumeric:
            descriptor.crossesAnchor(from: previousPosition, to: normalizedPosition)
        }
        if providesFeedback,
           shouldProvideFeedback {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        lastAnchorIndices[control.id] = anchorIndex
        lastSliderPositions[control.id] = normalizedPosition
    }

    private func settleAndSaveSlider(
        for control: ModelRequestBodyControl,
        descriptor: ModelRequestBodyControlSliderDescriptor
    ) {
        guard let state else { return }
        let currentPosition = descriptor.position(in: state)
        let restingPosition = descriptor.restingPosition(for: currentPosition)
        if abs(restingPosition - currentPosition) > 0.000_001 {
            UISelectionFeedbackGenerator().selectionChanged()
            if reduceMotion {
                updateSliderPosition(
                    restingPosition,
                    for: control,
                    descriptor: descriptor,
                    providesFeedback: false
                )
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    updateSliderPosition(
                        restingPosition,
                        for: control,
                        descriptor: descriptor,
                        providesFeedback: false
                    )
                }
            }
        }
        enqueueSliderSave(restingPosition, control: control)
    }

    private func enqueueSliderSave(_ position: Double, control: ModelRequestBodyControl) {
        let previousSaveTask = pendingSaveTask
        let modelKey = runnableModel.id
        let modelControls = runnableModel.model.requestBodyControls
        pendingSaveTask = Task(priority: .utility) {
            await previousSaveTask?.value
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                ModelRequestBodyControlRuntimeStore.saveSliderPosition(
                    position,
                    for: control,
                    forModelKey: modelKey,
                    controls: modelControls
                )
            }.value
        }
    }
}
