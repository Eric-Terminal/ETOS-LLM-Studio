import SwiftUI

/// 手表端的语音录制与转写面板
struct SpeechRecorderView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        let processingTitle = viewModel.sendSpeechAsAudio ? "正在发送…" : "正在转换…"
        let processingDescription = viewModel.sendSpeechAsAudio ? "录音会作为音频附件发送给当前模型。" : "请稍候，正在将语音转换为文本。"
        return VStack(spacing: 16) {
            if viewModel.speechTranscriptionInProgress {
                ProgressView(processingTitle)
                    .progressViewStyle(.circular)
                    .padding(.vertical, 4)
                Text(processingDescription)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                if viewModel.isRecordingSpeech {
                    WaveformView(samples: viewModel.waveformSamples)
                        .frame(height: 44)
                        .animation(.easeOut(duration: 0.12), value: viewModel.waveformSamples)
                        .padding(.top, 2)
                    
                    Text(formattedDuration(viewModel.recordingDuration))
                        .font(.system(.title3, design: .monospaced))
                        .monospacedDigit()
                    
                    Text("正在录音…")
                        .font(.headline)
                } else {
                    Image(systemName: "mic.slash")
                        .font(.system(size: 34))
                        .foregroundColor(.accentColor)
                        .padding(.top, 6)
                    Text(viewModel.sendSpeechAsAudio ? "录音后将直接发送" : "准备录音")
                        .font(.headline)
                }
            }
            
            HStack(spacing: 12) {
                Button("取消", role: .cancel) {
                    viewModel.cancelSpeechRecording()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.speechTranscriptionInProgress)
                .frame(maxWidth: .infinity)
                
                Button("完成录音") {
                    viewModel.finishSpeechRecording()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isRecordingSpeech || viewModel.speechTranscriptionInProgress)
                .frame(maxWidth: .infinity)
            }
        }
        
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear {
            Task { await viewModel.startSpeechRecording() }
        }
        .onDisappear {
            if viewModel.isRecordingSpeech {
                viewModel.cancelSpeechRecording()
            }
        }
        .onChange(of: viewModel.isSpeechRecorderPresented, initial: false) { _, presented in
            if !presented {
                dismiss()
            }
        }
    }
    
    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}


private struct WaveformView: View {
    var samples: [CGFloat]
    
    var body: some View {
        GeometryReader { proxy in
            let count = max(1, samples.count)
            let barWidth = proxy.size.width / CGFloat(count) * 0.6
            let spacing = proxy.size.width / CGFloat(count) * 0.4
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: barWidth, height: max(4, proxy.size.height * max(0.05, sample)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
        }
    }
}
