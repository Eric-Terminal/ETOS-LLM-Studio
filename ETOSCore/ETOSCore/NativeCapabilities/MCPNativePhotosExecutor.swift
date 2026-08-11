// ============================================================================
// MCPNativePhotosExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// Photos 执行器。二进制资源只在受控 app:// 文件空间与系统照片库之间流转。
// ============================================================================

import Foundation
#if canImport(Photos)
import Photos
import UniformTypeIdentifiers
#endif

actor MCPNativePhotosExecutor {
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(Photos)
        switch toolName {
        case "photos.search":
            return try await search(arguments)
        case "photos.export_asset":
            return try await exportAsset(arguments)
        case "photos.save_asset":
            return try await saveAsset(arguments)
        case "photos.create_album":
            return try await createAlbum(arguments)
        case "photos.add_to_album":
            return try await addToAlbum(arguments)
        default:
            throw MCPBuiltInPersonalDataError.unsupportedTool(toolName)
        }
        #else
        throw MCPBuiltInPersonalDataError.unsupportedPlatform(
            NSLocalizedString("当前平台没有 Photos；请在 iPhone 上执行该工具。", comment: "Photos unavailable on current platform")
        )
        #endif
    }
}

#if canImport(Photos)
private extension MCPNativePhotosExecutor {
    func search(_ arguments: [String: Any]) async throws -> [String: Any] {
        try await requestAuthorization(level: .readWrite)
        let options = PHFetchOptions()
        var predicates: [NSPredicate] = []
        if let start = try arguments.personalDataDate("start_date") {
            predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate))
        }
        if let end = try arguments.personalDataDate("end_date") {
            predicates.append(NSPredicate(format: "creationDate <= %@", end as NSDate))
        }
        switch arguments.personalDataString("media_type") ?? "any" {
        case "image":
            predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        case "video":
            predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        case "any":
            break
        default:
            throw MCPBuiltInPersonalDataError.invalidArgument(
                NSLocalizedString("media_type 必须是 image、video 或 any。", comment: "Invalid photo media type")
            )
        }
        if !predicates.isEmpty {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let query = (arguments.personalDataString("query") ?? "").localizedLowercase
        let limit = min(max(arguments.personalDataInt("limit") ?? 50, 1), 200)
        let fetch = PHAsset.fetchAssets(with: options)
        var assets: [[String: Any]] = []
        fetch.enumerateObjects { asset, _, stop in
            let item = self.assetPayload(asset)
            if query.isEmpty || ((item["filename"] as? String)?.localizedLowercase.contains(query) == true) {
                assets.append(item)
            }
            if assets.count >= limit {
                stop.pointee = true
            }
        }
        return result(toolName: "photos.search", extra: ["assets": assets, "count": assets.count])
    }

    func exportAsset(_ arguments: [String: Any]) async throws -> [String: Any] {
        try await requestAuthorization(level: .readWrite)
        let identifier = try arguments.personalDataRequiredString("asset_id")
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              let resource = PHAssetResource.assetResources(for: asset).first else {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                NSLocalizedString("找不到指定照片资源。", comment: "Photo asset not found")
            )
        }

        let destination = arguments.personalDataString("destination")
            ?? "app://NativeExports/Photos/\(safeFilename(resource.originalFilename))"
        let url = try MCPNativeFileAccess.writableURL(for: destination)
        let destinationExists = FileManager.default.fileExists(atPath: url.path)
        if destinationExists {
            guard arguments.personalDataBool("overwrite") == true else {
                throw MCPBuiltInPersonalDataError.invalidArgument(
                    NSLocalizedString("目标文件已存在；如需覆盖，请显式设置 overwrite。", comment: "Photo export destination exists")
                )
            }
        }

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".etos-photo-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: temporaryURL, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        if destinationExists {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: url)
        }
        StorageUtility.notifyFilesystemMutation(at: url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return result(toolName: "photos.export_asset", extra: [
            "exported": true,
            "asset": assetPayload(asset),
            "uri": MCPNativeFileAccess.appURI(for: url),
            "size_bytes": values.fileSize ?? 0
        ])
    }

    func saveAsset(_ arguments: [String: Any]) async throws -> [String: Any] {
        try await requestAuthorization(level: .addOnly)
        let source = try arguments.personalDataRequiredString("source")
        let url = try MCPNativeFileAccess.readableURL(for: source)
        let type = UTType(filenameExtension: url.pathExtension)
        var createdIdentifier: String?
        try await performChanges {
            let request: PHAssetChangeRequest?
            if type?.conforms(to: .movie) == true {
                request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } else if type?.conforms(to: .image) == true {
                request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            } else {
                request = nil
            }
            createdIdentifier = request?.placeholderForCreatedAsset?.localIdentifier
        }
        guard let createdIdentifier else {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                NSLocalizedString("源文件不是 Photos 支持的图片或视频。", comment: "Unsupported Photos source file")
            )
        }
        return result(toolName: "photos.save_asset", extra: [
            "saved": true,
            "asset_id": createdIdentifier,
            "source": source
        ])
    }

    func createAlbum(_ arguments: [String: Any]) async throws -> [String: Any] {
        try await requestAuthorization(level: .readWrite)
        let title = try arguments.personalDataRequiredString("title")
        var identifier: String?
        try await performChanges {
            identifier = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let identifier else {
            throw MCPBuiltInPersonalDataError.unavailable(
                NSLocalizedString("系统没有返回新相簿 ID。", comment: "Created album identifier unavailable")
            )
        }
        return result(toolName: "photos.create_album", extra: [
            "created": true,
            "album_id": identifier,
            "title": title
        ])
    }

    func addToAlbum(_ arguments: [String: Any]) async throws -> [String: Any] {
        try await requestAuthorization(level: .readWrite)
        let albumID = try arguments.personalDataRequiredString("album_id")
        let assetIDs = try arguments.personalDataRequiredStringArray("asset_ids")
        let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
        guard let album = albums.firstObject else {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                NSLocalizedString("找不到指定照片相簿。", comment: "Photo album not found")
            )
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        guard assets.count == assetIDs.count else {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                NSLocalizedString("一个或多个照片资源 ID 不存在。", comment: "Photo assets missing")
            )
        }
        try await performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album) else { return }
            request.addAssets(assets)
        }
        return result(toolName: "photos.add_to_album", extra: [
            "saved": true,
            "album_id": albumID,
            "asset_ids": assetIDs,
            "count": assetIDs.count
        ])
    }

    func requestAuthorization(level: PHAccessLevel) async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: level)
        let status = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: level)
            : current
        switch status {
        case .authorized, .limited:
            return
        case .denied, .restricted:
            throw MCPBuiltInPersonalDataError.permissionDenied(
                NSLocalizedString("照片图库访问权限不足。", comment: "Photos permission insufficient")
            )
        case .notDetermined:
            throw MCPBuiltInPersonalDataError.permissionDenied(
                NSLocalizedString("照片图库权限尚未确定。", comment: "Photos permission undetermined")
            )
        @unknown default:
            throw MCPBuiltInPersonalDataError.permissionDenied(
                NSLocalizedString("未知照片图库权限状态。", comment: "Unknown Photos permission")
            )
        }
    }

    func performChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MCPBuiltInPersonalDataError.unavailable(
                        NSLocalizedString("照片图库没有完成更改。", comment: "Photos change failed")
                    ))
                }
            }
        }
    }

    func assetPayload(_ asset: PHAsset) -> [String: Any] {
        let resource = PHAssetResource.assetResources(for: asset).first
        return [
            "id": asset.localIdentifier,
            "media_type": asset.mediaType == .video ? "video" : "image",
            "filename": resource?.originalFilename ?? "",
            "creation_date": MCPBuiltInPersonalDataDateCodec.string(asset.creationDate) ?? NSNull(),
            "modification_date": MCPBuiltInPersonalDataDateCodec.string(asset.modificationDate) ?? NSNull(),
            "width": asset.pixelWidth,
            "height": asset.pixelHeight,
            "duration_seconds": asset.duration,
            "is_favorite": asset.isFavorite
        ]
    }

    func safeFilename(_ filename: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let components = filename.components(separatedBy: invalid).filter { !$0.isEmpty }
        return components.joined(separator: "_").isEmpty ? UUID().uuidString : components.joined(separator: "_")
    }

    func result(toolName: String, extra: [String: Any]) -> [String: Any] {
        var output: [String: Any] = [
            "provider": "etos_builtin_personal_data",
            "tool_name": toolName
        ]
        output.merge(extra) { _, new in new }
        return output
    }
}
#endif

private extension Dictionary where Key == String, Value == Any {
    func personalDataRequiredStringArray(_ key: String) throws -> [String] {
        guard let values = self[key] as? [Any] else {
            throw MCPBuiltInPersonalDataError.missingArgument(key)
        }
        let result = values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !result.isEmpty, result.count == values.count else {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                String(format: NSLocalizedString("%@ 必须是非空字符串数组。", comment: "Invalid string array argument"), key)
            )
        }
        return result
    }
}
