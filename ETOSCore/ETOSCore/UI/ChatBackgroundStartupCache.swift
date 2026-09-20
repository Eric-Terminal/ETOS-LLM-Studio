import Foundation
import ImageIO
import UIKit

/// 启动专用的派生缓存。UserDefaults 仅保存最后一张位图的索引，设置真值仍由数据库管理。
public actor ChatBackgroundStartupCache {
    public static let shared = ChatBackgroundStartupCache()

    private struct Metadata: Equatable, Sendable {
        let name: String
        let radius: Double
        let target: DisplayImageTarget
        let sourceRevision: String

        init(name: String, radius: Double, target: DisplayImageTarget, sourceRevision: String) {
            self.name = name
            self.radius = radius
            self.target = target
            self.sourceRevision = sourceRevision
        }

        init?(dictionary: [String: Any]) {
            guard let name = dictionary["name"] as? String,
                  let radius = dictionary["radius"] as? Double,
                  let width = dictionary["width"] as? Int,
                  let height = dictionary["height"] as? Int,
                  let fillsBounds = dictionary["fillsBounds"] as? Bool,
                  let revision = dictionary["sourceRevision"] as? String else { return nil }
            self.init(name: name, radius: radius,
                      target: DisplayImageTarget(size: CGSize(width: width, height: height), scale: 1, fillsBounds: fillsBounds),
                      sourceRevision: revision)
        }

        var dictionary: [String: Any] {
            ["name": name, "radius": radius, "width": target.width, "height": target.height,
             "fillsBounds": target.fillsBounds, "sourceRevision": sourceRevision]
        }
    }

    private struct Snapshot: @unchecked Sendable {
        let metadata: Metadata
        let image: UIImage
    }

    private final class MemoryCache: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: Snapshot?

        func get() -> Snapshot? {
            lock.lock()
            defer { lock.unlock() }
            return snapshot
        }

        func set(_ snapshot: Snapshot) {
            lock.lock()
            self.snapshot = snapshot
            lock.unlock()
        }
    }

    private static let metadataKey = "chatBackground.startupBitmap.v1"
    public nonisolated let initialTarget: DisplayImageTarget?
    private nonisolated let memory: MemoryCache
    private let preloadTask: Task<Snapshot?, Never>
    private let cacheURL: URL
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard, cacheURL: URL = URL.cachesDirectory.appendingPathComponent("chat-background-startup.png")) {
        let memory = MemoryCache()
        self.memory = memory
        self.userDefaults = userDefaults
        let metadata = userDefaults.dictionary(forKey: Self.metadataKey).flatMap(Metadata.init(dictionary:))
        initialTarget = metadata?.target
        let url = cacheURL
        self.cacheURL = url
        // 从应用入口即开始解码，不等 GeometryReader 的首轮 task，更不依赖数据库预热。
        preloadTask = Task.detached(priority: .userInitiated) {
            guard let metadata,
                  metadata.sourceRevision == Self.sourceRevision(named: metadata.name),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(
                    source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                  ) else { return nil }
            let snapshot = Snapshot(metadata: metadata, image: UIImage(cgImage: image))
            memory.set(snapshot)
            return snapshot
        }
    }

    /// 视图模型首帧仅查看内存；磁盘尚未就绪时由异步路径补齐。
    public nonisolated func cachedImage(named name: String, radius: Double) -> UIImage? {
        guard let snapshot = memory.get(), snapshot.metadata.name == name,
              snapshot.metadata.radius == radius else { return nil }
        return snapshot.image
    }

    public func image(named name: String, radius: Double, target: DisplayImageTarget) async -> UIImage? {
        _ = await preloadTask.value
        guard let snapshot = memory.get(), snapshot.metadata.name == name,
              snapshot.metadata.radius == radius, snapshot.metadata.target == target,
              snapshot.metadata.sourceRevision == Self.sourceRevision(named: name) else { return nil }
        return snapshot.image
    }

    public func store(_ image: UIImage, named name: String, radius: Double,
                      target: DisplayImageTarget, sourceRevision: String) async {
        // 旧预热结果不能覆盖本次启动刚生成的新壁纸。
        _ = await preloadTask.value
        let metadata = Metadata(name: name, radius: radius, target: target, sourceRevision: sourceRevision)
        guard memory.get()?.metadata != metadata else { return }
        memory.set(Snapshot(metadata: metadata, image: image))
        guard let data = image.pngData() else { return }
        do {
            try data.write(to: cacheURL, options: .atomic)
            userDefaults.set(metadata.dictionary, forKey: Self.metadataKey)
        } catch {
            // 缓存失败不影响当前壁纸；下次启动仍可从原图后台重建。
        }
    }

    private nonisolated static func sourceRevision(named name: String) -> String? {
        let url = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(name)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        return "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)"
    }
}
