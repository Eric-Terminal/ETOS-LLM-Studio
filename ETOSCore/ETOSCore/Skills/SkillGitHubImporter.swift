// ============================================================================
// SkillGitHubImporter.swift
// ============================================================================
// 从 GitHub 导入 Agent Skills
// - 支持仓库根目录或 tree 子路径
// - 递归下载目录下全部文件
// - 要求目录中必须存在 SKILL.md
// ============================================================================

import Foundation

public enum SkillGitHubImporter {
    struct GitHubRepoInfo: Equatable {
        let owner: String
        let repo: String
        let branch: String
        let path: String
    }

    struct GitHubListedFile: Equatable {
        let relativePath: String
        let downloadURL: String
    }

    struct GitHubSelectedFiles: Equatable {
        let files: [GitHubListedFile]
        let fallbackName: String?
    }

    private struct GitHubContentItem: Decodable {
        let type: String
        let path: String
        let downloadURL: String?

        enum CodingKeys: String, CodingKey {
            case type
            case path
            case downloadURL = "download_url"
        }
    }

    public static func importSkill(from repoURL: String) async throws -> SkillImportResult {
        guard let info = parseGitHubURL(repoURL) else {
            throw SkillStoreError.networkError("无效的 GitHub 仓库链接。")
        }

        var files: [GitHubListedFile] = []
        try await listFilesRecursively(
            owner: info.owner,
            repo: info.repo,
            branch: info.branch,
            dirPath: info.path,
            basePath: info.path,
            result: &files
        )

        let selected = try selectedFilesForImport(files)
        guard !selected.files.isEmpty else {
            throw SkillStoreError.networkError("仓库目录为空，未找到可导入文件。")
        }

        var fileContents: [String: Data] = [:]
        for file in selected.files {
            let data = try await downloadData(url: file.downloadURL)
            fileContents[file.relativePath] = data
        }

        guard let skillData = fileContents["SKILL.md"],
              let skillMD = String(data: skillData, encoding: .utf8) else {
            throw SkillStoreError.missingSkillFile
        }
        let fallbackName = selected.fallbackName
            ?? fallbackSkillName(from: info.path)
            ?? fallbackRepoName(from: info.repo)
        let manifest = try SkillManifestResolver.resolve(content: skillMD, fallbackName: fallbackName)

        return SkillImportResult(skillName: manifest.name, files: fileContents)
    }

    static func parseGitHubURL(_ url: String) -> GitHubRepoInfo? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased() else {
            return nil
        }

        let pathComponents = decodedPathComponents(from: components.percentEncodedPath)
        if host == "github.com" {
            return parseGitHubWebURL(pathComponents)
        }
        if host == "raw.githubusercontent.com" {
            return parseGitHubRawURL(pathComponents)
        }
        return nil
    }

    private static func listFilesRecursively(
        owner: String,
        repo: String,
        branch: String,
        dirPath: String,
        basePath: String,
        result: inout [GitHubListedFile]
    ) async throws {
        let url = try makeGitHubContentsAPIURL(owner: owner, repo: repo, branch: branch, path: dirPath)
        let data = try await fetchData(url: url)
        let items = try JSONDecoder().decode([GitHubContentItem].self, from: data)

        for item in items {
            switch item.type {
            case "file":
                guard let downloadURL = item.downloadURL, !downloadURL.isEmpty else {
                    throw SkillStoreError.networkError("下载地址缺失：\(item.path)")
                }
                let relative = makeRelativePath(itemPath: item.path, basePath: basePath)
                guard !relative.isEmpty else { continue }
                result.append(GitHubListedFile(relativePath: relative, downloadURL: downloadURL))
            case "dir":
                try await listFilesRecursively(
                    owner: owner,
                    repo: repo,
                    branch: branch,
                    dirPath: item.path,
                    basePath: basePath,
                    result: &result
                )
            default:
                continue
            }
        }
    }

    static func selectedFilesForImport(_ files: [GitHubListedFile]) throws -> GitHubSelectedFiles {
        let rootFiles = normalizedFiles(files, rootPrefix: "")
        if rootFiles.contains(where: { $0.relativePath == SkillStore.defaultSkillFileName }) {
            return GitHubSelectedFiles(files: rootFiles, fallbackName: nil)
        }

        let skillFilePaths = files
            .map(\.relativePath)
            .filter { URL(fileURLWithPath: $0).lastPathComponent == SkillStore.defaultSkillFileName }
        guard skillFilePaths.count == 1, let skillFilePath = skillFilePaths.first else {
            if skillFilePaths.count > 1 {
                throw SkillStoreError.saveFailed("仓库中找到多个 SKILL.md，请使用 GitHub tree 链接指向具体技能目录。")
            }
            throw SkillStoreError.missingSkillFile
        }

        let rootPrefix = String(skillFilePath.dropLast(SkillStore.defaultSkillFileName.count))
        let rootName = rootPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .last
            .map(String.init)
        return GitHubSelectedFiles(files: normalizedFiles(files, rootPrefix: rootPrefix), fallbackName: rootName)
    }

    private static func normalizedFiles(_ files: [GitHubListedFile], rootPrefix: String) -> [GitHubListedFile] {
        files.compactMap { file in
            guard file.relativePath.hasPrefix(rootPrefix) else { return nil }
            let relativePath = String(file.relativePath.dropFirst(rootPrefix.count))
            guard let normalizedPath = SkillResourcePolicy.normalizeRelativePath(relativePath) else {
                return nil
            }
            return GitHubListedFile(relativePath: normalizedPath, downloadURL: file.downloadURL)
        }
    }

    private static func makeRelativePath(itemPath: String, basePath: String) -> String {
        let normalizedItem = itemPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedBase = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedItem.isEmpty else { return "" }
        guard !normalizedBase.isEmpty else { return normalizedItem }
        if normalizedItem == normalizedBase {
            return ""
        }
        let prefix = normalizedBase + "/"
        if normalizedItem.hasPrefix(prefix) {
            return String(normalizedItem.dropFirst(prefix.count))
        }
        return normalizedItem
    }

    static func makeGitHubContentsAPIURL(
        owner: String,
        repo: String,
        branch: String,
        path: String
    ) throws -> URL {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedPath: String
        if normalizedPath.isEmpty {
            encodedPath = ""
        } else {
            encodedPath = normalizedPath
                .split(separator: "/")
                .map { segment in
                    String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(segment)
                }
                .joined(separator: "/")
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        if encodedPath.isEmpty {
            components.path = "/repos/\(owner)/\(repo)/contents"
        } else {
            components.path = "/repos/\(owner)/\(repo)/contents/\(encodedPath)"
        }
        if !branch.isEmpty && branch != "HEAD" {
            components.queryItems = [URLQueryItem(name: "ref", value: branch)]
        }
        guard let url = components.url else {
            throw SkillStoreError.networkError("无法构造 GitHub API 地址。")
        }
        return url
    }

    private static func parseGitHubWebURL(_ pathComponents: [String]) -> GitHubRepoInfo? {
        guard pathComponents.count >= 2 else { return nil }
        let owner = pathComponents[0]
        let repo = normalizedRepoName(pathComponents[1])
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        guard pathComponents.count > 2 else {
            return GitHubRepoInfo(owner: owner, repo: repo, branch: "HEAD", path: "")
        }
        guard pathComponents.count >= 4,
              pathComponents[2] == "tree" || pathComponents[2] == "blob" || pathComponents[2] == "raw" else {
            return nil
        }

        guard let split = splitBranchAndPath(from: pathComponents.dropFirst(3)) else {
            return nil
        }
        let branch = split.branch
        let rawPath = split.path
        let path = pathComponents[2] == "tree" ? rawPath : directoryPathForBlob(rawPath)
        return GitHubRepoInfo(owner: owner, repo: repo, branch: branch, path: path)
    }

    private static func parseGitHubRawURL(_ pathComponents: [String]) -> GitHubRepoInfo? {
        guard pathComponents.count >= 4 else { return nil }
        let owner = pathComponents[0]
        let repo = normalizedRepoName(pathComponents[1])
        guard let split = splitBranchAndPath(from: pathComponents.dropFirst(2)) else {
            return nil
        }
        let branch = split.branch
        let rawPath = split.path
        guard !owner.isEmpty, !repo.isEmpty, !branch.isEmpty else { return nil }
        return GitHubRepoInfo(owner: owner, repo: repo, branch: branch, path: directoryPathForBlob(rawPath))
    }

    private static func splitBranchAndPath(from components: ArraySlice<String>) -> (branch: String, path: String)? {
        guard !components.isEmpty else { return nil }
        let componentArray = Array(components)
        if let skillRootIndex = skillRootIndex(in: componentArray), skillRootIndex > 0 {
            let branch = componentArray[..<skillRootIndex].joined(separator: "/")
            let path = componentArray[skillRootIndex...].joined(separator: "/")
            return branch.isEmpty ? nil : (branch, path)
        }
        let branch = componentArray[0]
        let path = componentArray.dropFirst().joined(separator: "/")
        return branch.isEmpty ? nil : (branch, path)
    }

    private static func skillRootIndex(in components: [String]) -> Int? {
        guard components.count >= 2 else { return nil }
        for index in 0..<(components.count - 1) where components[index] == ".claude" && components[index + 1] == "skills" {
            return index
        }
        return nil
    }

    private static func decodedPathComponents(from percentEncodedPath: String) -> [String] {
        percentEncodedPath
            .split(separator: "/")
            .map { String($0).removingPercentEncoding ?? String($0) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedRepoName(_ repo: String) -> String {
        repo.hasSuffix(".git") ? String(repo.dropLast(4)) : repo
    }

    private static func directoryPathForBlob(_ path: String) -> String {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard URL(fileURLWithPath: normalized).lastPathComponent == SkillStore.defaultSkillFileName else {
            return normalized
        }
        let directory = URL(fileURLWithPath: normalized).deletingLastPathComponent().relativePath
        return directory == "." ? "" : directory
    }

    private static func fallbackSkillName(from path: String) -> String? {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { return nil }
        let name = URL(fileURLWithPath: normalized).lastPathComponent
        return SkillPaths.isValidSkillName(name) ? name : nil
    }

    private static func fallbackRepoName(from repo: String) -> String? {
        SkillPaths.isValidSkillName(repo) ? repo : nil
    }

    private static func fetchData(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await NetworkSessionConfiguration.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SkillStoreError.networkError("GitHub 响应无效。")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SkillStoreError.networkError("GitHub 请求失败（\(http.statusCode)）。")
        }
        return data
    }

    private static func downloadData(url: String) async throws -> Data {
        guard let targetURL = URL(string: url) else {
            throw SkillStoreError.networkError("下载链接无效：\(url)")
        }
        return try await fetchData(url: targetURL)
    }
}
