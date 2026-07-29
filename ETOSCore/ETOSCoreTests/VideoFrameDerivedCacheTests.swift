// ============================================================================
// VideoFrameDerivedCacheTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证视频派生帧可跨缓存实例复用，并按源内容与抽帧设置自动失效。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

private actor VideoExtractionInvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@Suite("视频派生帧缓存")
struct VideoFrameDerivedCacheTests {
    @Test("相同视频与设置会跨缓存实例复用派生帧")
    func reusesDerivedFramesAcrossCacheInstances() async throws {
        let root = temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = VideoExtractionInvocationCounter()
        let attachment = makeAttachment(data: Data(repeating: 0x2A, count: 256))
        let configuration = makeConfiguration()

        let firstCache = VideoFrameDerivedCache(
            rootDirectory: root,
            algorithmVersion: 81,
            maximumMemoryUsage: 0
        )
        let first = try await firstCache.result(
            for: attachment,
            configuration: configuration
        ) {
            await counter.increment()
            return makeResult(payload: Data([0x01, 0x02]))
        }

        let secondCache = VideoFrameDerivedCache(
            rootDirectory: root,
            algorithmVersion: 81,
            maximumMemoryUsage: 0
        )
        let second = try await secondCache.result(
            for: attachment,
            configuration: configuration
        ) {
            await counter.increment()
            return makeResult(payload: Data([0xFF]))
        }

        #expect(await counter.value == 1)
        #expect(first.frames.first?.attachment.data == Data([0x01, 0x02]))
        #expect(second.frames.first?.attachment.data == Data([0x01, 0x02]))
        #expect(second.frames.first?.timestamp == 1.25)
        #expect(second.frames.first?.attachment.fileName.contains("cached-video_frame_001") == true)
    }

    @Test("修改抽帧设置会生成新的派生缓存")
    func configurationChangesInvalidateCache() async throws {
        let root = temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = VideoExtractionInvocationCounter()
        let cache = VideoFrameDerivedCache(rootDirectory: root, algorithmVersion: 82)
        let attachment = makeAttachment(data: Data(repeating: 0x11, count: 256))
        let smart = makeConfiguration()
        let fixed = VideoFrameExtractionConfiguration(
            mode: .fixedFPS,
            fixedFPS: 2,
            maximumFrameCount: 30
        )

        _ = try await cache.result(for: attachment, configuration: smart) {
            await counter.increment()
            return makeResult(payload: Data([0x01]))
        }
        _ = try await cache.result(for: attachment, configuration: fixed) {
            await counter.increment()
            return makeResult(payload: Data([0x02]))
        }

        #expect(await counter.value == 2)
    }

    @Test("源视频指纹变化不会误用旧派生帧")
    func sourceFingerprintChangesInvalidateCache() async throws {
        let root = temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = VideoExtractionInvocationCounter()
        let cache = VideoFrameDerivedCache(rootDirectory: root, algorithmVersion: 83)
        let firstAttachment = makeAttachment(data: Data(repeating: 0x01, count: 256))
        let changedAttachment = makeAttachment(data: Data(repeating: 0x02, count: 256))
        let configuration = makeConfiguration()

        _ = try await cache.result(for: firstAttachment, configuration: configuration) {
            await counter.increment()
            return makeResult(payload: Data([0x01]))
        }
        _ = try await cache.result(for: changedAttachment, configuration: configuration) {
            await counter.increment()
            return makeResult(payload: Data([0x02]))
        }

        #expect(await counter.value == 2)
    }

    @Test("相同视频的并发请求只执行一次抽帧")
    func concurrentRequestsShareExtraction() async throws {
        let root = temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = VideoExtractionInvocationCounter()
        let cache = VideoFrameDerivedCache(rootDirectory: root, algorithmVersion: 84)
        let attachment = makeAttachment(data: Data(repeating: 0x33, count: 256))
        let configuration = makeConfiguration()

        async let first = cache.result(for: attachment, configuration: configuration) {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return makeResult(payload: Data([0x03]))
        }
        async let second = cache.result(for: attachment, configuration: configuration) {
            await counter.increment()
            return makeResult(payload: Data([0x04]))
        }
        let results = try await [first, second]

        #expect(await counter.value == 1)
        #expect(results[0].frames.first?.attachment.data == results[1].frames.first?.attachment.data)
    }

    private func temporaryCacheRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("video-frame-cache-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeAttachment(data: Data) -> FileAttachment {
        FileAttachment(
            data: data,
            mimeType: "video/mp4",
            fileName: "cached-video.mp4"
        )
    }

    private func makeConfiguration() -> VideoFrameExtractionConfiguration {
        VideoFrameExtractionConfiguration(
            mode: .smart,
            fixedFPS: 1,
            maximumFrameCount: 30
        )
    }

    private func makeResult(payload: Data) -> VideoFrameExtractionResult {
        VideoFrameExtractionResult(
            frames: [
                ExtractedVideoFrame(
                    attachment: ImageAttachment(
                        data: payload,
                        mimeType: "image/jpeg",
                        fileName: "producer-frame.jpg"
                    ),
                    timestamp: 1.25
                )
            ],
            duration: 5
        )
    }
}
