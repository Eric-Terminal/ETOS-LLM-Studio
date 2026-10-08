import AVFoundation
import ETOSCore
import Foundation

protocol MacSpeechRecording: Actor {
    func start(format: AudioRecordingFormat, stopped: @escaping @MainActor @Sendable () -> Void) async throws
    func finish() async throws -> AudioAttachment
    func discard() async
}

/// 音频设备启停、文件写入与读回都在后台 actor 执行；界面只接收完成的附件。
actor MacSpeechRecorder: MacSpeechRecording {
    private var recorder: AVAudioRecorder?
    private var delegate: MacSpeechRecorderDelegate?
    private var url: URL?
    private var format = AudioRecordingFormat.aac

    func start(format: AudioRecordingFormat, stopped: @escaping @MainActor @Sendable () -> Void) throws {
        discard()
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).\(format.fileExtension)")
        self.url = url; self.format = format
        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.settings(format))
            let delegate = MacSpeechRecorderDelegate(stopped: stopped)
            recorder.delegate = delegate
            self.recorder = recorder; self.delegate = delegate
            guard recorder.prepareToRecord(), recorder.record() else { throw RecordingError.start }
            try Task.checkCancellation()
        } catch { discard(); throw error }
    }

    func finish() throws -> AudioAttachment {
        guard let url, let recorder else { throw RecordingError.missing }
        recorder.stop()
        defer { discard() }
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw RecordingError.missing }
        return AudioAttachment(data: data, mimeType: format.mimeType, format: format.fileExtension, fileName: url.lastPathComponent)
    }

    func discard() {
        recorder?.delegate = nil; recorder?.stop(); recorder = nil; delegate = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
    }

    static func settings(_ format: AudioRecordingFormat) -> [String: Any] {
        switch format {
        case .aac: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
        case .wav: [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        @unknown default: Self.settings(.aac)
        }
    }

    private enum RecordingError: LocalizedError {
        case start, missing
        var errorDescription: String? {
            switch self {
            case .start: NSLocalizedString("录音启动失败。", comment: "")
            case .missing: NSLocalizedString("录音文件未找到，无法处理。", comment: "")
            }
        }
    }
}

private final class MacSpeechRecorderDelegate: NSObject, AVAudioRecorderDelegate {
    let stopped: @MainActor @Sendable () -> Void
    init(stopped: @escaping @MainActor @Sendable () -> Void) { self.stopped = stopped }
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [stopped] in stopped() }
    }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [stopped] in stopped() }
    }
}
