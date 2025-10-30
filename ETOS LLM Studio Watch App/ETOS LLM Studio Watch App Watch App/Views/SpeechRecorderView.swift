import SwiftUI

/// 手表端的语音录制与转写面板
struct SpeechRecorderView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 14) {
            if viewModel.speechTranscriptionInProgress {
                ProgressView("正在转换…")
                    .progressViewStyle(.circular)
                    .padding(.vertical, 4)
                Text("请稍候，正在将语音转换为文本。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: viewModel.isRecordingSpeech ? "waveform.and.mic" : "mic.slash")
                    .font(.system(size: 34))
                    .foregroundColor(.accentColor)
                    .padding(.top, 6)
                Text(viewModel.isRecordingSpeech ? "正在录音…" : "准备录音")
                    .font(.headline)
                
                Button("完成录音") {
                    viewModel.finishSpeechRecording()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isRecordingSpeech)
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
    }
}
