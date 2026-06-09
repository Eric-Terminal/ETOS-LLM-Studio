// ============================================================================
// WatchInlineSpeechComposerView.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 watchOS 聊天输入栏内嵌语音输入胶囊。
// ============================================================================

import SwiftUI

struct WatchInlineSpeechComposerView: View {
    @ObservedObject var viewModel: ChatViewModel
    let inputControlHeight: CGFloat
    let inputFillColor: Color
    let inputStrokeColor: Color
    let onCancel: () -> Void
    let onStop: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        Group {
            if viewModel.isRecordingSpeech || viewModel.isSpeechRecordingPreparing {
                recordingCapsule
            } else {
                previewRow
            }
        }
        .frame(height: inputControlHeight)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: viewModel.isSpeechRecordingPreparing)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: viewModel.isRecordingSpeech)
        .animation(.easeOut(duration: 0.16), value: viewModel.speechTranscriptionInProgress)
        .task {
            await viewModel.startSpeechRecording()
        }
    }

    private var recordingCapsule: some View {
        HStack(spacing: 8) {
            WatchInlineVoiceWaveformView(
                samples: viewModel.waveformSamples,
                tint: .red,
                minimumBarOpacity: 0.85,
                isProcessing: false
            )
            .frame(height: inputControlHeight * 0.6)

            Text(formattedDuration(viewModel.recordingDuration, prefix: ""))
                .etFont(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.red)

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .etFont(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: inputControlHeight, height: inputControlHeight)
                    .background(Circle().fill(Color.red.opacity(0.78)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("停止录音", comment: ""))
            .disabled(viewModel.isSpeechRecordingPreparing)
            .opacity(viewModel.isSpeechRecordingPreparing ? 0.58 : 1)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, minHeight: inputControlHeight)
        .background(
            Capsule()
                .fill(inputFillColor)
                .overlay(Capsule().stroke(inputStrokeColor, lineWidth: 0.6))
        )
    }

    private var previewRow: some View {
        HStack(spacing: 6) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .etFont(.system(size: 14, weight: .semibold))
                    .frame(width: inputControlHeight, height: inputControlHeight)
                    .background(Circle().fill(inputFillColor))
                    .overlay(Circle().stroke(inputStrokeColor, lineWidth: 0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("取消录音", comment: ""))
            .disabled(viewModel.speechTranscriptionInProgress)

            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .etFont(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: inputControlHeight * 0.72, height: inputControlHeight)

                WatchInlineVoiceWaveformView(
                    samples: viewModel.waveformSamples,
                    tint: .secondary,
                    minimumBarOpacity: 0.55,
                    isProcessing: viewModel.speechTranscriptionInProgress
                )
                .frame(height: inputControlHeight * 0.58)

                Text(formattedDuration(viewModel.recordingDuration, prefix: "+ "))
                    .etFont(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                if viewModel.speechTranscriptionInProgress {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: inputControlHeight, height: inputControlHeight)
                        .accessibilityLabel(NSLocalizedString("语音转写中", comment: ""))
                } else {
                    Button(action: onConfirm) {
                        Image(systemName: "arrow.up")
                            .etFont(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: inputControlHeight, height: inputControlHeight)
                            .background(Circle().fill(Color.blue))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(viewModel.sendSpeechAsAudio ? NSLocalizedString("添加语音附件", comment: "") : NSLocalizedString("开始语音转写", comment: ""))
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 3)
            .frame(maxWidth: .infinity, minHeight: inputControlHeight)
            .background(
                Capsule()
                    .fill(inputFillColor)
                    .overlay(Capsule().stroke(inputStrokeColor, lineWidth: 0.6))
            )
        }
    }

    private func formattedDuration(_ duration: TimeInterval, prefix: String) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "\(prefix)%d:%02d", minutes, seconds)
    }
}

private struct WatchInlineVoiceWaveformView: View {
    let samples: [CGFloat]
    let tint: Color
    let minimumBarOpacity: Double
    let isProcessing: Bool

    var body: some View {
        GeometryReader { proxy in
            let displaySamples = normalizedSamples
            let count = max(1, displaySamples.count)
            let unitWidth = proxy.size.width / CGFloat(count)
            let barWidth = max(1.4, min(3, unitWidth * 0.45))
            let spacing = max(1.2, unitWidth - barWidth)

            ZStack {
                bars(
                    samples: displaySamples,
                    height: proxy.size.height,
                    barWidth: barWidth,
                    spacing: spacing
                )
                .opacity(isProcessing ? 0.62 : 1)

                if isProcessing {
                    processingSweep(containerWidth: proxy.size.width)
                        .mask(
                            bars(
                                samples: displaySamples,
                                height: proxy.size.height,
                                barWidth: barWidth,
                                spacing: spacing
                            )
                        )
                        .blendMode(.plusLighter)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .accessibilityHidden(true)
        }
    }

    private var normalizedSamples: [CGFloat] {
        let usable = samples.isEmpty ? Array(repeating: 0.08, count: 24) : samples
        return usable.map { max(0.05, min(1, $0)) }
    }

    private func bars(
        samples: [CGFloat],
        height: CGFloat,
        barWidth: CGFloat,
        spacing: CGFloat
    ) -> some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                Capsule()
                    .fill(tint.opacity(max(minimumBarOpacity, 0.45 + Double(sample) * 0.55)))
                    .frame(width: barWidth, height: max(3, height * (0.16 + sample * 0.84)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func processingSweep(containerWidth: CGFloat) -> some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.15) / 1.15
            LinearGradient(
                colors: [.clear, tint.opacity(0.08), tint.opacity(0.95), tint.opacity(0.08), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(32, containerWidth * 0.82))
            .offset(x: -containerWidth + containerWidth * 2 * phase)
        }
    }
}
