// ============================================================================
// ChatRequestBodyControlRows.swift
// ============================================================================
// ETOS LLM Studio
//
// 复用模型请求控制的加载、交互与持久化视图。
// ============================================================================

import SwiftUI
import UIKit
import ETOSCore

struct ChatRequestBodyControlRows: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let runnableModel: RunnableModel
    let controls: [ModelRequestBodyControl]

    @State private var state: ModelRequestBodyControlState?
    @State private var pendingSaveTask: Task<Void, Never>?
    @State private var lastAnchorIndices: [String: Int] = [:]
    @State private var lastSliderPositions: [String: Double] = [:]
    @State private var sliderDescriptors: [String: ModelRequestBodyControlSliderDescriptor] = [:]
    @State private var optionTitlesByControlID: [String: [String: String]] = [:]

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
                    optionMenuRow(for: control)
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
            let optionTitles = Dictionary(
                uniqueKeysWithValues: modelControls.map { control in
                    (
                        control.id,
                        Dictionary(uniqueKeysWithValues: control.options.map { ($0.id, $0.title) })
                    )
                }
            )
            return (loadedState, descriptors, optionTitles)
        }.value
        guard !Task.isCancelled else { return }
        state = loaded.0
        sliderDescriptors = loaded.1
        optionTitlesByControlID = loaded.2
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

    private func optionMenuRow(for control: ModelRequestBodyControl) -> some View {
        Menu {
            if control.options.isEmpty {
                Text(NSLocalizedString("这个控制还没有选项。", comment: ""))
            } else {
                ForEach(control.options) { option in
                    Button {
                        selectOption(option.id, for: control)
                    } label: {
                        if selectedOptionID(for: control) == option.id {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(control.title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(selectedOptionTitle(for: control))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .etFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state == nil || control.options.isEmpty)
    }

    private func selectedOptionID(for control: ModelRequestBodyControl) -> String {
        state?.selectedOptionIDsByControlID[control.id]
            ?? control.defaultOptionID
            ?? control.options.first?.id
            ?? ""
    }

    private func selectedOptionTitle(for control: ModelRequestBodyControl) -> String {
        let selectedID = selectedOptionID(for: control)
        return optionTitlesByControlID[control.id]?[selectedID]
            ?? NSLocalizedString("未选择", comment: "")
    }

    private func selectOption(_ optionID: String, for control: ModelRequestBodyControl) {
        guard var updatedState = state else { return }
        updatedState.selectedOptionIDsByControlID[control.id] = optionID
        updatedState = ModelRequestBodyControlCompiler.normalized(
            updatedState,
            for: runnableModel.model.requestBodyControls
        )
        state = updatedState

        let previousSaveTask = pendingSaveTask
        let modelKey = runnableModel.id
        let modelControls = runnableModel.model.requestBodyControls
        let stateToSave = updatedState
        pendingSaveTask = Task(priority: .utility) {
            await previousSaveTask?.value
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                ModelRequestBodyControlRuntimeStore.save(
                    stateToSave,
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
        let showsFlowingRainbow = control.usesRainbowAtMaximum
            && descriptor.isMaximumPosition(position)

        return VStack {
            HStack {
                Text(control.title)
                    .lineLimit(1)
                Spacer()
                Group {
                    if showsFlowingRainbow {
                        FlowingRainbowForeground(
                            startingColor: palette.color(at: 1)
                        ) {
                            sliderValueLabel(
                                text: displayValue,
                                position: position,
                                isNumeric: descriptor.mode == .continuousNumeric
                            )
                        }
                    } else {
                        sliderValueLabel(
                            text: displayValue,
                            position: position,
                            isNumeric: descriptor.mode == .continuousNumeric
                        )
                        .foregroundStyle(palette.color(at: position))
                    }
                }
                .lineLimit(1)
            }

            RequestBodyGradientSlider(
                value: sliderBinding(for: control, descriptor: descriptor),
                palette: palette,
                anchorCount: descriptor.optionCount,
                adjustmentStep: descriptor.crownStep,
                accessibilityLabel: control.title,
                accessibilityValue: displayValue,
                showsFlowingRainbow: showsFlowingRainbow,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        settleAndSaveSlider(for: control, descriptor: descriptor)
                    }
                }
            )
        }
        .disabled(state == nil)
    }

    private func sliderValueLabel(
        text: String,
        position: Double,
        isNumeric: Bool
    ) -> some View {
        RequestBodySliderAnimatedValue(
            text: text,
            position: position,
            isNumeric: isNumeric
        )
        .etFont(.footnote.monospaced())
    }

    private func sliderPalette(for control: ModelRequestBodyControl) -> RequestBodySliderPalette {
        RequestBodySliderPalette.resolved(for: control)
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
