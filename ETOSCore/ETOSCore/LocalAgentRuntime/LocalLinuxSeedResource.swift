// ============================================================================
// LocalLinuxSeedResource.swift
// ============================================================================
// ETOS LLM Studio
// ============================================================================

import Foundation

public struct LocalLinuxSeedResource: Equatable, Sendable {
    public let archiveURL: URL
    public let metadataURL: URL
    public let metadata: LocalLinuxSeedMetadata

    public static func load(from bundle: Bundle = .main) throws -> LocalLinuxSeedResource {
        let archiveURL = resourceURL(
            bundle: bundle,
            name: "ETOSLocalLinuxRootFSSeed",
            extension: "tar.gz"
        )
        let metadataURL = resourceURL(
            bundle: bundle,
            name: "ETOSLocalLinuxRootFSSeed",
            extension: "json"
        )
        guard let archiveURL, let metadataURL else {
            throw LocalLinuxRuntimeError.seedResourceMissing
        }
        let metadata = try JSONDecoder().decode(
            LocalLinuxSeedMetadata.self,
            from: Data(contentsOf: metadataURL)
        )
        try validate(metadata: metadata, archiveURL: archiveURL)
        return LocalLinuxSeedResource(
            archiveURL: archiveURL,
            metadataURL: metadataURL,
            metadata: metadata
        )
    }

    private static func resourceURL(
        bundle: Bundle,
        name: String,
        extension fileExtension: String
    ) -> URL? {
        bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "LocalLinux")
            ?? bundle.url(forResource: name, withExtension: fileExtension)
    }

    private static func validate(metadata: LocalLinuxSeedMetadata, archiveURL: URL) throws {
        guard metadata.format == "ish-rootfs-seed-archive-v1" else {
            throw LocalLinuxRuntimeError.invalidSeedMetadata("format")
        }
        guard metadata.guestArchitecture == "aarch64" else {
            throw LocalLinuxRuntimeError.invalidSeedMetadata("guestArchitecture")
        }
        guard metadata.compression == "gzip",
              metadata.archiveSHA256.count == 64,
              metadata.archiveSHA256.allSatisfy(\.isHexDigit),
              metadata.upstreamArchiveSHA256.count == 64,
              metadata.entryCount != 0,
              metadata.uncompressedBytes != 0 else {
            throw LocalLinuxRuntimeError.invalidSeedMetadata("archive")
        }
        let values = try archiveURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              UInt64(values.fileSize ?? -1) == metadata.archiveBytes else {
            throw LocalLinuxRuntimeError.invalidSeedMetadata("archiveBytes")
        }
    }
}
