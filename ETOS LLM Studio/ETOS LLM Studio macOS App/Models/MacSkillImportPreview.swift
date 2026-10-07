import ETOSCore
import Foundation

enum MacSkillImportSource: Sendable {
    case file(URL), github(String), url(String)
}

struct MacSkillImportPreview: Sendable {
    let result: SkillImportResult
    let expectedVersion: String?
    let fileCount: Int
    let size: String

    nonisolated static func prepare(_ source: MacSkillImportSource) async throws -> Self {
        let result: SkillImportResult
        switch source {
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            result = try SkillBundleImporter.importSkill(from: url)
        case .github(let raw):
            result = try await SkillGitHubImporter.importSkill(from: raw)
        case .url(let raw):
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw SkillStoreError.networkError(NSLocalizedString("仅支持 http/https 链接。", comment: ""))
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 45
            let (download, response) = try await SyncPackageUploadService.downloadTemporaryFile(request: request)
            defer { try? FileManager.default.removeItem(at: download) }
            if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
                throw SkillStoreError.networkError(String(format: NSLocalizedString("下载失败：HTTP %d", comment: ""), response.statusCode))
            }
            try Task.checkCancellation()
            let suggested = response.suggestedFilename
            let fileName = suggested?.isEmpty != false || suggested?.caseInsensitiveCompare("SKILL.md") == .orderedSame ? url.path : suggested
            result = try SkillBundleImporter.importSkill(fromDownloadedData: Data(contentsOf: download), suggestedFileName: fileName)
        }
        try Task.checkCancellation()
        let existing = SkillStore.listSkills().first { $0.name == result.skillName }
        let version = try existing.map { try SkillRunSnapshotBuilder.build(skill: $0).versionDigest }
        return Self(result: result, expectedVersion: version, fileCount: result.files.count,
                    size: StorageUtility.formatSize(result.files.values.reduce(Int64(0)) { $0 + Int64($1.count) }))
    }
}
