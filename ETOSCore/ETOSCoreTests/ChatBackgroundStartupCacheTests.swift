import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import ETOSCore

@Suite("聊天壁纸启动缓存", .serialized)
struct ChatBackgroundStartupCacheTests {
    @Test("重建缓存实例后直接恢复显示位图，设置变化和原图替换使其失效")
    func restoresPreparedBitmapAndInvalidatesChanges() async throws {
        let suite = "background-startup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(suite).png"
        let sourceURL = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(name)
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: sourceURL)
        }
        let context = try #require(CGContext(
            data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 320,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let source = UIImage(cgImage: try #require(context.makeImage()))
        try #require(source.pngData()).write(to: sourceURL)
        let target = DisplayImageTarget(size: CGSize(width: 20, height: 20), scale: 1)
        let prepared = try #require(await DisplayImageLoader().background(named: name, target: target))
        let cacheURL = directory.appendingPathComponent("bitmap.png")
        let cache = ChatBackgroundStartupCache(userDefaults: defaults, cacheURL: cacheURL)
        #expect(await cache.image(named: name, radius: 0, target: target) == nil)
        await cache.store(prepared.image, named: name, radius: 0, target: target, sourceRevision: prepared.sourceRevision)

        let restored = ChatBackgroundStartupCache(userDefaults: defaults, cacheURL: cacheURL)
        #expect(restored.initialTarget == target)
        let image = try #require(await restored.image(named: name, radius: 0, target: target))
        #expect(image.size == prepared.image.size)
        #expect(restored.cachedImage(named: name, radius: 0) === image)
        #expect(await restored.image(named: "另一个背景.png", radius: 0, target: target) == nil)
        #expect(await restored.image(named: name, radius: 5, target: target) == nil)
        let resized = DisplayImageTarget(size: CGSize(width: 40, height: 20), scale: 1)
        #expect(await restored.image(named: name, radius: 0, target: resized) == nil)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: sourceURL.path)
        #expect(await restored.image(named: name, radius: 0, target: target) == nil)
        let replaced = ChatBackgroundStartupCache(userDefaults: defaults, cacheURL: cacheURL)
        #expect(await replaced.image(named: name, radius: 0, target: target) == nil)
        #expect(replaced.cachedImage(named: name, radius: 0) == nil)
        try FileManager.default.removeItem(at: sourceURL)
        #expect(await cache.image(named: name, radius: 0, target: target) == nil)
    }
}
