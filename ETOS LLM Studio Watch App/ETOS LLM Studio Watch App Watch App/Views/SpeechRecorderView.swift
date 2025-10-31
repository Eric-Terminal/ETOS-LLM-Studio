import SwiftUI

/// 手表端的语音录制与转写面板
struct SpeechRecorderView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        let processingTitle = viewModel.sendSpeechAsAudio ? "正在发送…" : "正在转换…"
        let processingDescription = viewModel.sendSpeechAsAudio ? "录音会作为音频附件发送给当前模型。" : "请稍候，正在将语音转换为文本。"
        return VStack(spacing: 14) {
            if viewModel.speechTranscriptionInProgress {
                ProgressView(processingTitle)
                    .progressViewStyle(.circular)
                    .padding(.vertical, 4)
                Text(processingDescription)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: viewModel.isRecordingSpeech ? "waveform.and.mic" : "mic.slash")
                    .font(.system(size: 34))
                    .foregroundColor(.accentColor)
                    .padding(.top, 6)
                Text(viewModel.isRecordingSpeech ? "正在录音…" : (viewModel.sendSpeechAsAudio ? "录音后将直接发送" : "准备录音"))
                    .font(.headline)
                
                Button("完成录音") {
                    viewModel.finishSpeechRecording()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isRecordingSpeech || viewModel.speechTranscriptionInProgress)
            }
            
            Button("取消", role: .cancel) {
                viewModel.cancelSpeechRecording()
                dismiss()
            }
            .disabled(viewModel.speechTranscriptionInProgress)
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
        .onChange(of: viewModel.isSpeechRecorderPresented) { presented in
            if !presented {
                dismiss()
            }
        }
    }
}
