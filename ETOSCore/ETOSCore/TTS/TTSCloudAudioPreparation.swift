import AVFoundation
import Foundation

/// 在进入播放和重播缓存前统一为 PCM，让三端播放与导出共用同一次边界平滑。
enum TTSCloudAudioPreparation {
    static func prepare(_ clip: TTSManager.AudioClip) async throws -> TTSManager.AudioClip {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            var pcm: TTSManager.AudioClip
            let format = clip.format.lowercased()
            if format == "pcm" || format.hasPrefix("pcm_") {
                pcm = clip
                pcm.format = "pcm"
                pcm.sampleRate = clip.sampleRate ?? 24_000
            } else {
                pcm = try decode(clip.data)
            }
            try fadeEdges(of: &pcm)
            try Task.checkCancellation()
            return pcm
        }
        return try await withTaskCancellationHandler {
            let prepared = try await task.value
            try Task.checkCancellation()
            return prepared
        } onCancel: { task.cancel() }
    }

    private static func decode(_ data: Data) throws -> TTSManager.AudioClip {
        // AVAudioFile 需要文件 URL；临时源文件只用于解码，成功、失败和取消时都删除。
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tts-\(UUID().uuidString).audio")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
            throw TTSCloudAudioError.decode
        }
        let frameCount = file.length
        var pcm = Data()
        while file.framePosition < frameCount {
            try Task.checkCancellation()
            // 新 SDK 会把越过文件尾的读取视为错误，最后一批只读取剩余帧。
            let remaining = AVAudioFrameCount(min(Int64(buffer.frameCapacity), frameCount - file.framePosition))
            try file.read(into: buffer, frameCount: remaining)
            guard buffer.frameLength > 0 else { throw TTSCloudAudioError.decode }
            let audioBuffer = buffer.audioBufferList.pointee.mBuffers
            guard let samples = audioBuffer.mData else { throw TTSCloudAudioError.decode }
            pcm.append(samples.assumingMemoryBound(to: UInt8.self), count: Int(audioBuffer.mDataByteSize))
        }
        return .init(data: pcm, format: "pcm", sampleRate: Int(file.processingFormat.sampleRate),
                     channels: Int(file.processingFormat.channelCount))
    }

    private static func fadeEdges(of clip: inout TTSManager.AudioClip) throws {
        guard let sampleRate = clip.sampleRate, sampleRate > 0,
              clip.channels > 0, clip.channels <= Int(UInt16.max) / 2,
              sampleRate <= Int(UInt32.max) / (clip.channels * 2),
              !clip.data.isEmpty, clip.data.count.isMultiple(of: clip.channels * 2) else {
            throw TTSCloudAudioError.decode
        }
        let channels = clip.channels
        let frameCount = clip.data.count / (channels * 2)
        // 按采样帧计算 10ms；短片段将窗口缩至半段，不插入静音、不删除采样或改变时长。
        let fadeFrames = min(max(1, sampleRate / 100), (frameCount + 1) / 2)
        clip.data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for frame in 0..<fadeFrames {
                let gain = fadeFrames > 1 ? Double(frame) / Double(fadeFrames - 1) : 0
                applyGain(gain, frame: frame, channels: channels, bytes: bytes)
                applyGain(gain, frame: frameCount - 1 - frame, channels: channels, bytes: bytes)
            }
        }
    }

    private static func applyGain(_ gain: Double, frame: Int, channels: Int, bytes: UnsafeMutableRawBufferPointer) {
        for channel in 0..<channels {
            let offset = (frame * channels + channel) * 2
            // 网络 PCM 是交错排列的小端 Int16；逐字节读写不依赖 Data 的内存对齐。
            let sample = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
            let faded = UInt16(bitPattern: Int16((Double(sample) * gain).rounded()))
            bytes[offset] = UInt8(truncatingIfNeeded: faded)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: faded >> 8)
        }
    }
}
