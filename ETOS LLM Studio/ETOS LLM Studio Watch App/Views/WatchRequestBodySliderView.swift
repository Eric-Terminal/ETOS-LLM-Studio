// ============================================================================
// WatchRequestBodySliderView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 以纵向液位控制呈现结构化选项滑块，支持触摸拖动与数码表冠调整。
// ============================================================================

import SwiftUI
import WatchKit
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
            liquidControl(size: geometry.size)
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

        return ZStack(alignment: .bottom) {
            Capsule()
                .fill(.thinMaterial)

            Rectangle()
                .fill(WatchRequestBodySliderPalette.gradient)
                .mask(alignment: .bottom) {
                    Rectangle()
                        .frame(height: fillHeight)
                }
                .mask(Capsule())

            anchorMarks(color: Color.secondary.opacity(0.55))

            anchorMarks(color: Color.white.opacity(0.82))
                .mask(alignment: .bottom) {
                    Rectangle()
                        .frame(height: fillHeight)
                }

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
            Capsule()
                .stroke(
                    WatchRequestBodySliderPalette.color(at: position).opacity(0.48),
                    lineWidth: 1
                )
        }
        .contentShape(Capsule())
        .opacity(isLoaded ? 1 : 0.65)
        .gesture(dragGesture(height: size.height))
        .focusable(true)
        .digitalCrownRotation(
            crownBinding,
            from: 0,
            through: 1,
            by: descriptor.crownStep,
            sensitivity: .medium,
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

    private func anchorMarks(color: Color) -> some View {
        VStack(spacing: 0) {
            ForEach(Array((0..<descriptor.optionCount).reversed()), id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if index > 0 {
                    Spacer(minLength: 0)
                }
            }
        }
        .padding()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
            try? await Task.sleep(for: .milliseconds(320))
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

private enum WatchRequestBodySliderPalette {
    static let gradient = LinearGradient(
        colors: [
            color(at: 0),
            color(at: 0.34),
            color(at: 0.68),
            color(at: 1)
        ],
        startPoint: .bottom,
        endPoint: .top
    )

    static func color(at position: Double) -> Color {
        let normalizedPosition = min(max(position, 0), 1)
        return Color(
            hue: 0.58 + normalizedPosition * 0.29,
            saturation: 0.72,
            brightness: 0.94
        )
    }
}
