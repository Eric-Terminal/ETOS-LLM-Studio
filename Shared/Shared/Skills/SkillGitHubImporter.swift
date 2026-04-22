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
    private struct GitHubRepoInfo {
        let owner: String
        let repo: String
        let branch: String
        let path: String
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

        var files: [(relativePath: String, downloadURL: String)] = []
        try await listFilesRecursively(
            owner: info.owner,
            repo: info.repo,
            branch: info.branch,
            dirPath: info.path,
            basePath: info.path,
            result: &files
        )

        guard !files.isEmpty else {
            throw SkillStoreError.networkError("仓库目录为空，未找到可导入文件。")
        }
        guard files.contains(where: { $0.relativePath == "SKILL.md" }) else {
            throw SkillStoreError.missingSkillFile
        }

        var fileContents: [String: String] = [:]
        for file in files {
            let content = try await downloadText(url: file.downloadURL)
            fileContents[file.relativePath] = content
        }

        guard let skillMD = fileContents["SKILL.md"] else {
            throw SkillStoreError.missingSkillFile
        }
        let frontmatter = SkillFrontmatterParser.parse(skillMD)
        guard let skillName = frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !skillName.isEmpty else {
            throw SkillStoreError.invalidSkillContent
        }

        return SkillImportResult(skillName: skillName, files: fileContents)
    }

    private static func parseGitHubURL(_ url: String) -> GitHubRepoInfo? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let regex = try! NSRegularExpression(
            pattern: #"^https://github\.com/([^/]+)/([^/]+)(?:/tree/([^/]+)(/.*)?)?$"#,
            options: [.caseInsensitive]
        )
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range) else { return nil }

        func value(at index: Int) -> String {
            guard let range = Range(match.range(at: index), in: trimmed), match.range(at: index).location != NSNotFound else {
                return ""
            }
            return String(trimmed[range])
        }

        let owner = value(at: 1)
        let repo = value(at: 2)
        let branch = value(at: 3).isEmpty ? "HEAD" : value(at: 3)
        let rawPath = value(at: 4).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return GitHubRepoInfo(owner: owner, repo: repo, branch: branch, path: rawPath)
    }

    private static func listFilesRecursively(
        owner: String,
        repo: String,
        branch: String,
        dirPath: String,
        basePath: String,
        result: inout [(relativePath: String, downloadURL: String)]
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
                result.append((relative, downloadURL))
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

    private static func makeGitHubContentsAPIURL(
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
        components.queryItems = [URLQueryItem(name: "ref", value: branch)]
        guard let url = components.url else {
            throw SkillStoreError.networkError("无法构造 GitHub API 地址。")
        }
        return url
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

    private static func downloadText(url: String) async throws -> String {
        guard let targetURL = URL(string: url) else {
            throw SkillStoreError.networkError("下载链接无效：\(url)")
        }
        let data = try await fetchData(url: targetURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SkillStoreError.networkError("文件不是 UTF-8 文本：\(targetURL.lastPathComponent)")
        }
        return text
    }
}
