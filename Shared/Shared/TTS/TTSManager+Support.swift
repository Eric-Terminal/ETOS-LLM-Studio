import Foundation
import Combine
import os.log
import AVFoundation

extension TTSManager: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playbackState.status = .ended
        if let continuation = audioContinuation {
            audioContinuation = nil
            continuation.resume()
        }
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        playbackState.status = .error
        playbackState.errorMessage = error?.localizedDescription
        if let continuation = audioContinuation {
            audioContinuation = nil
            continuation.resume(throwing: error ?? NSError(domain: "TTS", code: -11, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("音频解码失败。", comment: "")]))
        }
    }
}
extension TTSManager: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.speechDidStart = true
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.handleSpeechSynthesizerDidFinish()
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.handleSpeechSynthesizerDidCancel()
        }
    }

    @MainActor
    func handleSpeechSynthesizerDidFinish() {
        stopSpeechMonitor()
        playbackState.status = .ended
        playbackState.position = playbackState.duration
        if let continuation = speechContinuation {
            speechContinuation = nil
            continuation.resume()
        }
    }

    @MainActor
    func handleSpeechSynthesizerDidCancel() {
        stopSpeechMonitor()
        if let continuation = speechContinuation {
            speechContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }
}
extension Float {
    func ttsClamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
extension Data {
    init?(hexString: String) {
        let cleaned = hexString.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            let byteString = cleaned[index..<next]
            guard let value = UInt8(byteString, radix: 16) else { return nil }
            bytes.append(value)
            index = next
        }
        self = bytes
    }
}
extension UInt16 {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }
}
extension UInt32 {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}
