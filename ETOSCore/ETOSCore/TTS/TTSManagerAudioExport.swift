// ============================================================================
// TTSManagerAudioExport.swift
// ============================================================================
// ETOS LLM Studio
//
// 保留最近一次完整网络朗读的内存音频，用于免请求重播和用户主动导出。
// ============================================================================

import Foundation

public struct TTSAudioExport: Sendable {
    public let data: Data
    public let fileExtension: String

    public init(data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension
    }
}

extension TTSManager {
    public var canExportLastNetworkAudio: Bool {
        cachedNetworkAudioExport != nil
    }

    public func lastNetworkAudioExport() -> TTSAudioExport? {
        cachedNetworkAudioExport
    }

    func recordNetworkAudioClip(_ clip: AudioClip, for itemID: UUID) {
        activeNetworkClips[itemID] = clip
        let orderedClips = activeNetworkItemIDs.compactMap { activeNetworkClips[$0] }
        let orderedTexts = activeNetworkItemIDs.compactMap { activeNetworkItemTexts[$0] }
        if orderedClips.count == activeNetworkItemIDs.count,
           orderedTexts.count == activeNetworkItemIDs.count {
            lastNetworkChunkTexts = orderedTexts
            lastNetworkAudioClips = orderedClips
            audioExportRevision &+= 1
            let revision = audioExportRevision
            // 长文本导出会复制整段音频，预先在后台生成，避免 SwiftUI 查询按钮状态时阻塞主线程。
            Task { [weak self] in
                let export = await Task.detached(priority: .utility) {
                    TTSAudioExportBuilder.make(from: orderedClips)
                }.value
                guard let self, revision == self.audioExportRevision else { return }
                self.cachedNetworkAudioExport = export
            }
        }
    }
}

enum TTSAudioExportBuilder {
    static func make(from clips: [TTSManager.AudioClip]) -> TTSAudioExport? {
        guard !clips.isEmpty else { return nil }
        let normalizedFormats = clips.map { normalizedExportFormat($0.format) }
        guard let format = normalizedFormats.first,
              normalizedFormats.allSatisfy({ $0 == format }) else { return nil }

        switch format {
        case "pcm":
            guard let first = clips.first,
                  clips.allSatisfy({
                      ($0.sampleRate ?? 24_000) == (first.sampleRate ?? 24_000) &&
                          $0.channels == first.channels
                  }) else { return nil }
            let pcm = clips.reduce(into: Data()) { $0.append($1.data) }
            return TTSAudioExport(
                data: makeWAV(
                    pcm: pcm,
                    sampleRate: first.sampleRate ?? 24_000,
                    channels: first.channels
                ),
                fileExtension: "wav"
            )
        case "wav":
            guard let wav = mergeWAVClips(clips) else { return nil }
            return TTSAudioExport(data: wav, fileExtension: "wav")
        case "mp3":
            return TTSAudioExport(
                data: clips.reduce(into: Data()) { $0.append($1.data) },
                fileExtension: "mp3"
            )
        case "flac":
            guard clips.count == 1 else { return nil }
            return TTSAudioExport(data: clips[0].data, fileExtension: "flac")
        case "opus", "ogg":
            guard clips.count == 1 else { return nil }
            return TTSAudioExport(data: clips[0].data, fileExtension: "ogg")
        default:
            guard clips.count == 1 else { return nil }
            return TTSAudioExport(data: clips[0].data, fileExtension: format)
        }
    }

    private static func normalizedExportFormat(_ format: String) -> String {
        let lowercased = format.lowercased()
        if lowercased.hasPrefix("mp3_") { return "mp3" }
        if lowercased.hasPrefix("pcm_") { return "pcm" }
        if lowercased.hasPrefix("opus_") { return "opus" }
        return lowercased
    }

    private static func mergeWAVClips(_ clips: [TTSManager.AudioClip]) -> Data? {
        guard let first = clips.first,
              let firstPayload = wavPayload(first.data),
              let format = wavFormat(first.data) else { return nil }
        var pcm = firstPayload
        for clip in clips.dropFirst() {
            guard let clipFormat = wavFormat(clip.data),
                  clipFormat.sampleRate == format.sampleRate,
                  clipFormat.channels == format.channels,
                  clipFormat.bitsPerSample == format.bitsPerSample,
                  let payload = wavPayload(clip.data) else { return nil }
            pcm.append(payload)
        }
        return makeWAV(
            pcm: pcm,
            sampleRate: format.sampleRate,
            channels: format.channels,
            bitsPerSample: format.bitsPerSample
        )
    }

    private static func wavFormat(_ data: Data) -> (sampleRate: Int, channels: Int, bitsPerSample: Int)? {
        guard data.count >= 36,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        let channels = Int(readLittleEndianUInt16(data, at: 22))
        let sampleRate = Int(readLittleEndianUInt32(data, at: 24))
        let bitsPerSample = Int(readLittleEndianUInt16(data, at: 34))
        guard channels > 0, sampleRate > 0, bitsPerSample > 0 else { return nil }
        return (sampleRate, channels, bitsPerSample)
    }

    private static func wavPayload(_ data: Data) -> Data? {
        guard data.count >= 12 else { return nil }
        var offset = 12
        while offset + 8 <= data.count {
            let identifier = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let size = Int(readLittleEndianUInt32(data, at: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= data.count else { return nil }
            if identifier == "data" {
                return data[payloadStart..<payloadEnd]
            }
            offset = payloadEnd + (size.isMultiple(of: 2) ? 0 : 1)
        }
        return nil
    }

    private static func makeWAV(
        pcm: Data,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int = 16
    ) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(UInt32(36 + pcm.count).ttsLittleEndianData)
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(UInt32(16).ttsLittleEndianData)
        wav.append(UInt16(1).ttsLittleEndianData)
        wav.append(UInt16(channels).ttsLittleEndianData)
        wav.append(UInt32(sampleRate).ttsLittleEndianData)
        wav.append(UInt32(byteRate).ttsLittleEndianData)
        wav.append(UInt16(blockAlign).ttsLittleEndianData)
        wav.append(UInt16(bitsPerSample).ttsLittleEndianData)
        wav.append("data".data(using: .ascii)!)
        wav.append(UInt32(pcm.count).ttsLittleEndianData)
        wav.append(pcm)
        return wav
    }

    private static func readLittleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readLittleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }
}

private extension UInt16 {
    var ttsLittleEndianData: Data {
        var value = littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }
}

private extension UInt32 {
    var ttsLittleEndianData: Data {
        var value = littleEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}
