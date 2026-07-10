// ============================================================================
// WatchRequestBodySliderView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 以纵向液位控制呈现结构化选项滑块，支持触摸拖动与数码表冠调整。
// ============================================================================

import SwiftUI
import WatchKit
import Foundation
import ETOSCore

struct WatchRequestBodySliderView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let runnableModel: RunnableModel
    let control: ModelRequestBodyControl
    let descriptor: ModelRequestBodyControlSliderDescriptor
    let onCommit: (Double) -> Void
    let onDone: () -> Void

    @State private var position: Double
    @State private var isLoaded = false
    @State private var isDragging = false
    @State private var lastAnchorIndex: Int
    @State private var lastPosition: Double
    @State private var settleTask: Task<Void, Never>?
    @State private var pendingSaveTask: Task<Void, Never>?

    init(
        runnableModel: RunnableModel,
        control: ModelRequestBodyControl,
        descriptor: ModelRequestBodyControlSliderDescriptor,
        onCommit: @escaping (Double) -> Void,
        onDone: @escaping () -> Void
    ) {
        self.runnableModel = runnableModel
        self.control = control
        self.descriptor = descriptor
        self.onCommit = onCommit
        self.onDone = onDone
        let initialPosition = descriptor.position(in: ModelRequestBodyControlState())
        _position = State(initialValue: initialPosition)
        _lastAnchorIndex = State(initialValue: descriptor.nearestAnchorIndex(at: initialPosition))
        _lastPosition = State(initialValue: initialPosition)
    }

    var body: some View {
        GeometryReader { geometry in
            let controlSize = CGSize(
                width: min(geometry.size.width * 0.56, geometry.size.height * 0.52),
                height: geometry.size.height
            )
            liquidControl(size: controlSize)
                .frame(width: controlSize.width, height: controlSize.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .navigationTitle(control.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("完成", comment: ""), action: onDone)
            }
        }
        .task(id: runnableModel.id) {
            await loadState()
        }
        .onDisappear {
            settleTask?.cancel()
            let restingPosition = descriptor.restingPosition(for: position)
            onCommit(restingPosition)
            enqueueSave(restingPosition)
        }
    }

    private func liquidControl(size: CGSize) -> some View {
        let fillHeight = size.height * descriptor.normalized(position)
        let displayValue = descriptor.displayValue(at: position)
        let palette = sliderPalette
        let shape = RoundedRectangle(
            cornerRadius: min(size.width, size.height) * 0.2,
            style: .continuous
        )

        return ZStack(alignment: .bottom) {
            shape
                .fill(.thinMaterial)

            Rectangle()
                .fill(palette.color(at: position))
                .mask(alignment: .bottom) {
                    Rectangle()
                        .frame(height: fillHeight)
                }
                .mask(shape)

            WatchLiquidScaleMarks(
                count: descriptor.optionCount,
                color: Color.primary.opacity(0.26)
            )

            Text(displayValue)
                .etFont(.title3.monospaced().weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            Text(displayValue)
                .etFont(.title3.monospaced().weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .mask {
                    Color.black
                        .frame(height: fillHeight)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
        }
        .overlay {
            shape
                .stroke(
                    palette.color(at: position).opacity(0.48),
                    lineWidth: 1
                )
        }
        .contentShape(shape)
        .opacity(isLoaded ? 1 : 0.65)
        .gesture(dragGesture(height: size.height))
        .focusable(true)
        .digitalCrownRotation(
            crownBinding,
            from: 0,
            through: 1,
            by: crownRotationStep,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: false
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(control.title))
        .accessibilityValue(Text(displayValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                updatePosition(position + descriptor.crownStep, schedulesSettle: true)
            case .decrement:
                updatePosition(position - descriptor.crownStep, schedulesSettle: true)
            @unknown default:
                break
            }
        }
    }

    private var sliderPalette: WatchRequestBodySliderPalette {
        control.options.contains { $0.payload.keys.contains("temperature") }
            ? .temperature
            : .structured
    }

    private var crownRotationStep: Double {
        switch descriptor.mode {
        case .discrete:
            return descriptor.anchorStep / 192
        case .continuousNumeric:
            return descriptor.crownStep / 32
        }
    }

    private var crownBinding: Binding<Double> {
        Binding(
            get: { position },
            set: { updatePosition($0, schedulesSettle: !isDragging) }
        )
    }

    private func dragGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isLoaded, height > 0 else { return }
                isDragging = true
                settleTask?.cancel()
                updatePosition(1 - Double(value.location.y / height), schedulesSettle: false)
            }
            .onEnded { value in
                guard isLoaded, height > 0 else { return }
                updatePosition(1 - Double(value.location.y / height), schedulesSettle: false)
                isDragging = false
                settleAndSave()
            }
    }

    private func updatePosition(_ newPosition: Double, schedulesSettle: Bool) {
        guard isLoaded else { return }
        let normalizedPosition = descriptor.normalized(newPosition)
        position = normalizedPosition
        let anchorIndex = descriptor.nearestAnchorIndex(at: normalizedPosition)
        let shouldProvideFeedback = switch descriptor.mode {
        case .discrete:
            anchorIndex != lastAnchorIndex
        case .continuousNumeric:
            descriptor.crossesAnchor(from: lastPosition, to: normalizedPosition)
        }
        if shouldProvideFeedback {
            WKInterfaceDevice.current().play(.click)
        }
        lastAnchorIndex = anchorIndex
        lastPosition = normalizedPosition
        if schedulesSettle {
            scheduleSettle()
        }
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            settleAndSave()
        }
    }

    private func settleAndSave() {
        settleTask?.cancel()
        let restingPosition = descriptor.restingPosition(for: position)
        if abs(restingPosition - position) > 0.000_001 {
            WKInterfaceDevice.current().play(.click)
            if reduceMotion {
                position = restingPosition
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    position = restingPosition
                }
            }
            lastAnchorIndex = descriptor.nearestAnchorIndex(at: restingPosition)
            lastPosition = restingPosition
        }
        onCommit(restingPosition)
        enqueueSave(restingPosition)
    }

    private func loadState() async {
        let modelKey = runnableModel.id
        let controls = runnableModel.model.requestBodyControls
        let loadedState = await Task.detached(priority: .userInitiated) {
            ModelRequestBodyControlRuntimeStore.state(
                forModelKey: modelKey,
                controls: controls
            )
        }.value
        guard !Task.isCancelled else { return }
        position = descriptor.position(in: loadedState)
        lastAnchorIndex = descriptor.nearestAnchorIndex(at: position)
        lastPosition = position
        isLoaded = true
    }

    private func enqueueSave(_ position: Double) {
        guard isLoaded else { return }
        let previousSaveTask = pendingSaveTask
        let modelKey = runnableModel.id
        let controls = runnableModel.model.requestBodyControls
        pendingSaveTask = Task(priority: .utility) {
            await previousSaveTask?.value
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                ModelRequestBodyControlRuntimeStore.saveSliderPosition(
                    position,
                    for: control,
                    forModelKey: modelKey,
                    controls: controls
                )
            }.value
        }
    }
}

struct WatchTemperatureSliderView: View {
    @Binding var value: Double

    @State private var lastFeedbackAnchor: Int?
    // 保留未四舍五入的表冠位置，避免细分步进被 0.01 精度吞掉。
    @State private var interactivePosition: Double?

    private let range = 0.0...2.0
    private let step = 0.01

    var body: some View {
        GeometryReader { geometry in
            let controlSize = CGSize(
                width: min(geometry.size.width * 0.56, geometry.size.height * 0.52),
                height: geometry.size.height
            )
            liquidControl(size: controlSize)
                .frame(width: controlSize.width, height: controlSize.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .navigationTitle(NSLocalizedString("温度", comment: "Temperature sampling parameter title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            interactivePosition = normalizedPosition
            lastFeedbackAnchor = feedbackAnchor(at: currentPosition)
        }
    }

    private func liquidControl(size: CGSize) -> some View {
        let position = currentPosition
        let fillHeight = size.height * position
        let displayValue = value.formatted(.number.precision(.fractionLength(2)))
        let palette = WatchRequestBodySliderPalette.temperature
        let shape = RoundedRectangle(
            cornerRadius: min(size.width, size.height) * 0.2,
            style: .continuous
        )

        return ZStack(alignment: .bottom) {
            shape
                .fill(.thinMaterial)

            Rectangle()
                .fill(palette.color(at: position))
                .mask(alignment: .bottom) {
                    Rectangle()
                        .frame(height: fillHeight)
                }
                .mask(shape)

            WatchLiquidScaleMarks(
                count: 3,
                color: Color.primary.opacity(0.26)
            )

            temperatureValue(displayValue, color: .primary)

            temperatureValue(displayValue, color: .white)
                .mask {
                    Color.black
                        .frame(height: fillHeight)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
        }
        .overlay {
            shape
                .stroke(palette.color(at: position).opacity(0.48), lineWidth: 1)
        }
        .contentShape(shape)
        .gesture(dragGesture(height: size.height))
        .focusable(true)
        .digitalCrownRotation(
            positionBinding,
            from: 0,
            through: 1,
            by: step / (range.upperBound - range.lowerBound) / 40,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: false
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(NSLocalizedString("温度", comment: "Temperature sampling parameter title")))
        .accessibilityValue(Text(displayValue))
        .accessibilityAdjustableAction { direction in
            let positionStep = step / (range.upperBound - range.lowerBound)
            switch direction {
            case .increment:
                updatePosition(position + positionStep)
            case .decrement:
                updatePosition(position - positionStep)
            @unknown default:
                break
            }
        }
    }

    private func temperatureValue(_ displayValue: String, color: Color) -> some View {
        Text(displayValue)
            .etFont(.title3.monospaced().weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var normalizedPosition: Double {
        let span = range.upperBound - range.lowerBound
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private var currentPosition: Double {
        interactivePosition ?? normalizedPosition
    }

    private var positionBinding: Binding<Double> {
        Binding(
            get: { currentPosition },
            set: { updatePosition($0) }
        )
    }

    private func dragGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard height > 0 else { return }
                updatePosition(1 - Double(drag.location.y / height))
            }
            .onEnded { drag in
                guard height > 0 else { return }
                updatePosition(1 - Double(drag.location.y / height))
            }
    }

    private func updatePosition(_ newPosition: Double) {
        let position = min(max(newPosition, 0), 1)
        interactivePosition = position
        let anchor = feedbackAnchor(at: position)
        if let lastFeedbackAnchor, anchor != lastFeedbackAnchor {
            WKInterfaceDevice.current().play(.click)
        }
        lastFeedbackAnchor = anchor

        let span = range.upperBound - range.lowerBound
        let rawValue = range.lowerBound + position * span
        value = min(max((rawValue / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    private func feedbackAnchor(at position: Double) -> Int {
        Int(min(max(position, 0), 1) * 2 + 0.000_001)
    }
}

private struct WatchLiquidScaleMarks: View {
    let count: Int
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ForEach(0..<count, id: \.self) { index in
                let position = count > 1
                    ? Double(index) / Double(count - 1)
                    : 0
                let rawY = geometry.size.height * (1 - position)
                let y = min(max(rawY, 1), geometry.size.height - 1)

                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * 0.22, height: 2)
                    .position(x: geometry.size.width / 2, y: y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum WatchRequestBodySliderPalette {
    case structured
    case temperature

    func color(at position: Double) -> Color {
        let normalizedPosition = min(max(position, 0), 1)
        switch self {
        case .structured:
            return Color(
                hue: 0.58 + normalizedPosition * 0.29,
                saturation: 0.72,
                brightness: 0.96 - normalizedPosition * 0.12
            )
        case .temperature:
            return Color(
                hue: 0.62 + normalizedPosition * 0.38,
                saturation: 0.78,
                brightness: 0.98 - normalizedPosition * 0.1
            )
        }
    }
}
