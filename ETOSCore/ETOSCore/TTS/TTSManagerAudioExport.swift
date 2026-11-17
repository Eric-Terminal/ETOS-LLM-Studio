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
            let previous = audioExportTask
            previous?.cancel()
            audioExportTask = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled else { return }
                let preparation = Task.detached(priority: .utility) {
                    guard !Task.isCancelled else { return nil as TTSAudioExport? }
                    return TTSAudioExportBuilder.make(from: orderedClips)
                }
                let export = await withTaskCancellationHandler {
                    await preparation.value
                } onCancel: { preparation.cancel() }
                guard !Task.isCancelled, let self, revision == self.audioExportRevision else { return }
                self.cachedNetworkAudioExport = export
            }
        }
    }
}

enum TTSAudioExportBuilder {
    static func make(from clips: [TTSManager.AudioClip]) -> TTSAudioExport? {
        // 分段已在预取时解码和平滑；这里只封装 WAV，不再拼接压缩文件或重复施加淡化。
        guard let first = clips.first,
              first.channels > 0, first.channels <= Int(UInt16.max) / 2 else { return nil }
        let sampleRate = first.sampleRate ?? 24_000
        guard sampleRate > 0, sampleRate <= Int(UInt32.max) / (first.channels * 2),
              clips.allSatisfy({
                  $0.format == "pcm" && ($0.sampleRate ?? 24_000) == sampleRate &&
                      $0.channels == first.channels && !$0.data.isEmpty &&
                      $0.data.count.isMultiple(of: first.channels * 2)
              }) else { return nil }
        let pcm = clips.reduce(into: Data()) { $0.append($1.data) }
        return TTSAudioExport(
            data: makeWAV(pcm: pcm, sampleRate: sampleRate, channels: first.channels),
            fileExtension: "wav"
        )
    }

    private static func makeWAV(
        pcm: Data,
        sampleRate: Int,
        channels: Int
    ) -> Data {
        let bitsPerSample = 16
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
