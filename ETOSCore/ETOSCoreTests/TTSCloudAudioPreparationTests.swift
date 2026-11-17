import AVFoundation
import Foundation
import Testing
@testable import ETOSCore

@Suite("云端朗读分段音频平滑")
struct TTSCloudAudioPreparationTests {
    @Test("24kHz 分段首尾各平滑 240 帧，中间采样和总时长不变")
    func tenMillisecondEdges() async throws {
        let source = pcmClip(Array(repeating: 23_900, count: 1_000))
        let prepared = try await TTSCloudAudioPreparation.prepare(source)
        let samples = samples(in: prepared.data)
        #expect(prepared.format == "pcm")
        #expect(prepared.sampleRate == 24_000)
        #expect(prepared.data.count == source.data.count)
        #expect(samples[0] == 0 && samples[999] == 0)
        #expect(samples[119] == 11_900 && samples[880] == 11_900)
        #expect(samples[239...760].allSatisfy { $0 == 23_900 })
        #expect(self.samples(in: source.data).allSatisfy { $0 == 23_900 })
    }

    @Test("48kHz 立体声两声道同帧淡化，保留正负满幅与声道顺序")
    func stereoAndSampleRate() async throws {
        let source = pcmClip(Array(repeating: [Int16.max, Int16.min], count: 1_200).flatMap { $0 },
                             sampleRate: 48_000, channels: 2)
        let prepared = try await TTSCloudAudioPreparation.prepare(source)
        let samples = samples(in: prepared.data)
        #expect(prepared.sampleRate == 48_000 && prepared.channels == 2)
        #expect(prepared.data.count == source.data.count)
        #expect(Array(samples.prefix(2)) == [0, 0])
        #expect(Array(samples.suffix(2)) == [0, 0])
        #expect(samples[240 * 2] > 0 && samples[240 * 2] < Int16.max)
        #expect(samples[240 * 2 + 1] < 0 && samples[240 * 2 + 1] > Int16.min)
        #expect(samples[479 * 2] == Int16.max && samples[479 * 2 + 1] == Int16.min)
        #expect(samples[720 * 2] == Int16.max && samples[720 * 2 + 1] == Int16.min)
    }

    @Test("不足 20ms 的片段缩短淡化窗口，单帧也安全归零", arguments: [1, 2, 3, 5, 12, 239, 479])
    func shortClips(frameCount: Int) async throws {
        let prepared = try await TTSCloudAudioPreparation.prepare(pcmClip(Array(repeating: 12_000, count: frameCount)))
        let samples = samples(in: prepared.data)
        #expect(samples.count == frameCount)
        #expect(samples.first == 0 && samples.last == 0)
        if frameCount >= 3 { #expect(samples[frameCount / 2] == 12_000) }
    }

    @Test("静音在平滑后仍为静音，缺省 PCM 采样率沿用 24kHz")
    func silenceAndDefaultRate() async throws {
        var source = pcmClip(Array(repeating: 0, count: 1_000))
        source.sampleRate = nil
        let prepared = try await TTSCloudAudioPreparation.prepare(source)
        #expect(prepared.sampleRate == 24_000)
        #expect(prepared.data == source.data)
    }

    @Test("WAV 按实际文件格式解码，跨多个缓冲读取后与裸 PCM 处理一致")
    func wavDecoding() async throws {
        let source = pcmClip(Array(repeating: [Int16(15_000), -15_000], count: 20_000).flatMap { $0 },
                             sampleRate: 44_100, channels: 2)
        let wav = try #require(TTSAudioExportBuilder.make(from: [source]))
        let decoded = try await TTSCloudAudioPreparation.prepare(.init(data: wav.data, format: "wav", sampleRate: nil))
        let preparedPCM = try await TTSCloudAudioPreparation.prepare(source)
        #expect(decoded.sampleRate == 44_100 && decoded.channels == 2)
        #expect(decoded.data == preparedPCM.data)
    }

    @Test("MP3 与 AAC 先解码再平滑，导出保留同一份处理后的采样", arguments: ["mp3", "aac"])
    func compressedAudio(format: String) async throws {
        let encoded: Data
        if format == "mp3" {
            // 自行生成的 100ms、440Hz 正弦波，覆盖默认 MP3 服务路径，无第三方音频素材。
            let bundle = Bundle(for: TTSAudioFixtureBundleMarker.self)
            let url = try #require(bundle.url(forResource: "TTSBoundaryTone", withExtension: "mp3"))
            encoded = try Data(contentsOf: url)
        } else {
            encoded = try makeAAC()
        }
        let prepared = try await TTSCloudAudioPreparation.prepare(.init(data: encoded, format: format, sampleRate: nil))
        let samples = samples(in: prepared.data)
        #expect(prepared.format == "pcm" && prepared.sampleRate == 24_000 && prepared.channels == 1)
        try #require(samples.count > 480)
        #expect(samples.first == 0 && samples.last == 0)
        #expect(samples[240..<(samples.count - 240)].contains { abs(Int($0)) > 1_000 })
        let exported = try #require(TTSAudioExportBuilder.make(from: [prepared]))
        #expect(exported.fileExtension == "wav")
        #expect(Data(exported.data.dropFirst(44)) == prepared.data)
    }

    @Test("导出两段音频不重复淡化，两侧接缝归零且不增加静音或丢帧")
    func joinedExport() async throws {
        let first = try await TTSCloudAudioPreparation.prepare(pcmClip(Array(repeating: 23_900, count: 1_000)))
        let second = try await TTSCloudAudioPreparation.prepare(pcmClip(Array(repeating: -23_900, count: 1_000)))
        let exported = try #require(TTSAudioExportBuilder.make(from: [first, second]))
        let payload = Data(exported.data.dropFirst(44))
        #expect(exported.fileExtension == "wav")
        #expect(payload == first.data + second.data)
        let samples = samples(in: payload)
        #expect(samples.count == 2_000)
        #expect(samples[999] == 0 && samples[1_000] == 0)
        #expect(samples[119] == 11_900 && samples[1_119] == -11_900)
    }

    @Test("空音频和不完整采样帧被拒绝，不静默截断数据")
    func invalidPCM() async {
        for clip in [
            pcmClip([]),
            TTSManager.AudioClip(data: Data([1]), format: "pcm", sampleRate: 24_000),
            pcmClip([1, 2, 3], channels: 2),
            pcmClip([1, 2], sampleRate: 0),
            pcmClip([1, 2], channels: 0)
        ] {
            await #expect(throws: TTSCloudAudioError.self) {
                try await TTSCloudAudioPreparation.prepare(clip)
            }
        }
    }

    @Test("损坏的压缩数据返回解码失败，不回退播放原始数据")
    func invalidEncodedAudio() async {
        await #expect(throws: (any Error).self) {
            try await TTSCloudAudioPreparation.prepare(.init(data: Data([1, 2, 3]), format: "mp3", sampleRate: nil))
        }
    }

    @Test("已取消任务不继续进行音频准备")
    func cancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TTSCloudAudioPreparation.prepare(pcmClip([1, 2, 3]))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("重播缓存与预取结果不再次淡化，也不重新请求服务")
    @MainActor
    func replayAndPrefetchReuse() async throws {
        let prepared = try await TTSCloudAudioPreparation.prepare(pcmClip(Array(repeating: 23_900, count: 1_000)))
        let manager = TTSManager(urlSession: .shared, settingsProvider: { .defaultValue }, serviceProvider: { nil })
        let cached = TTSManager.QueueItem(messageID: nil, text: "重播", playbackModeOverride: .cloud,
                                          serviceOverride: nil, settingsOverride: nil, cachedClip: prepared)
        let replay = try await manager.resolveCloudClip(for: cached, settings: .defaultValue)
        #expect(replay.data == prepared.data)
        let item = TTSManager.QueueItem(messageID: nil, text: "预取", playbackModeOverride: .cloud,
                                        serviceOverride: nil, settingsOverride: nil, cachedClip: nil)
        manager.prefetchTasks[item.id] = Task { prepared }
        let prefetched = try await manager.resolveCloudClip(for: item, settings: .defaultValue)
        #expect(prefetched.data == prepared.data)
        #expect(manager.prefetchTasks.isEmpty)
    }

    private func pcmClip(_ samples: [Int16], sampleRate: Int = 24_000, channels: Int = 1) -> TTSManager.AudioClip {
        let bytes = samples.flatMap { sample -> [UInt8] in
            let value = UInt16(bitPattern: sample)
            return [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
        }
        return .init(data: Data(bytes), format: "pcm", sampleRate: sampleRate, channels: channels)
    }

    private func samples(in data: Data) -> [Int16] {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: 2).map {
            Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
        }
    }

    /// 在测试中生成真实编码数据，避免依赖外部音频、网络服务或音频输出设备。
    private func makeAAC() throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tts-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        buffer.frameLength = 24_000
        let channel = try #require(buffer.floatChannelData?[0])
        for frame in 0..<24_000 {
            channel[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 24_000) * 0.5)
        }
        // 离开作用域后关闭编码器，确保读取到完整的容器尾部。
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
}

private final class TTSAudioFixtureBundleMarker: NSObject {}
