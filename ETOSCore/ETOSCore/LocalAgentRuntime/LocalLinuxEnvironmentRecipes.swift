// ============================================================================
// LocalLinuxEnvironmentRecipes.swift
// ============================================================================
// ETOS LLM Studio
//
// 这些命令随 App 版本固定并由用户主动执行。运行时、MCP 或 Skill 只可以提示，
// 不能自行触发安装或切换软件源。
// ============================================================================

import Foundation

public struct LocalLinuxPackageMirror: Identifiable, Hashable, Sendable {
    public let id: String
    public let baseURL: URL

    public var displayName: String {
        switch id {
        case "aliyun":
            return NSLocalizedString("阿里云镜像", comment: "Alibaba Cloud Alpine mirror name")
        case "tsinghua":
            return NSLocalizedString("清华大学镜像", comment: "Tsinghua Alpine mirror name")
        default:
            return NSLocalizedString("Alpine 官方 CDN", comment: "Official Alpine CDN name")
        }
    }
}

public struct LocalLinuxMirrorProbeResult: Equatable, Sendable {
    public let mirror: LocalLinuxPackageMirror
    public let latencyMilliseconds: Int?

    public init(mirror: LocalLinuxPackageMirror, latencyMilliseconds: Int?) {
        self.mirror = mirror
        self.latencyMilliseconds = latencyMilliseconds
    }
}

public struct LocalLinuxMirrorRecommendation: Equatable, Sendable {
    public let selectedMirror: LocalLinuxPackageMirror
    public let probeResults: [LocalLinuxMirrorProbeResult]

    public init(
        selectedMirror: LocalLinuxPackageMirror,
        probeResults: [LocalLinuxMirrorProbeResult]
    ) {
        self.selectedMirror = selectedMirror
        self.probeResults = probeResults
    }

    public var selectedLatencyMilliseconds: Int? {
        probeResults.first { $0.mirror.id == selectedMirror.id }?.latencyMilliseconds
    }

    public var isMeasured: Bool {
        selectedLatencyMilliseconds != nil
    }
}

public enum LocalLinuxPackageMirrors {
    public static let official = LocalLinuxPackageMirror(
        id: "official",
        baseURL: URL(string: "https://dl-cdn.alpinelinux.org/alpine")!
    )
    public static let aliyun = LocalLinuxPackageMirror(
        id: "aliyun",
        baseURL: URL(string: "https://mirrors.aliyun.com/alpine")!
    )
    public static let tsinghua = LocalLinuxPackageMirror(
        id: "tsinghua",
        baseURL: URL(string: "https://mirrors.tuna.tsinghua.edu.cn/alpine")!
    )

    public static let all = [official, aliyun, tsinghua]

    /// 不依赖定位权限；地区只在网络测速全部失败时决定默认建议。
    public static func regionalFallback(regionCode: String? = Locale.current.region?.identifier) -> LocalLinuxPackageMirror {
        regionCode?.uppercased() == "CN" ? aliyun : official
    }

    public static func recommend(
        regionCode: String? = Locale.current.region?.identifier
    ) async -> LocalLinuxMirrorRecommendation {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let results = await withTaskGroup(of: LocalLinuxMirrorProbeResult.self) { group in
            for mirror in all {
                group.addTask {
                    LocalLinuxMirrorProbeResult(
                        mirror: mirror,
                        latencyMilliseconds: await Self.probe(mirror, session: session)
                    )
                }
            }

            var measured: [LocalLinuxMirrorProbeResult] = []
            for await result in group {
                measured.append(result)
            }
            return all.compactMap { mirror in
                measured.first { $0.mirror.id == mirror.id }
            }
        }

        return recommendation(from: results, regionCode: regionCode)
    }

    static func recommendation(
        from results: [LocalLinuxMirrorProbeResult],
        regionCode: String?
    ) -> LocalLinuxMirrorRecommendation {
        let selected = results
            .filter { $0.latencyMilliseconds != nil }
            .min { lhs, rhs in
                let lhsLatency = lhs.latencyMilliseconds ?? .max
                let rhsLatency = rhs.latencyMilliseconds ?? .max
                if lhsLatency != rhsLatency { return lhsLatency < rhsLatency }
                return Self.candidateIndex(lhs.mirror) < Self.candidateIndex(rhs.mirror)
            }?
            .mirror ?? regionalFallback(regionCode: regionCode)
        return LocalLinuxMirrorRecommendation(selectedMirror: selected, probeResults: results)
    }

    private static func candidateIndex(_ mirror: LocalLinuxPackageMirror) -> Int {
        all.firstIndex { $0.id == mirror.id } ?? .max
    }

    /// HEAD 同时验证 main/community，避免只测首页却选到缺仓库的镜像。
    private static func probe(_ mirror: LocalLinuxPackageMirror, session: URLSession) async -> Int? {
        let startedAt = Date()
        for repository in ["main", "community"] {
            let indexURL = mirror.baseURL
                .appendingPathComponent("latest-stable")
                .appendingPathComponent(repository)
                .appendingPathComponent("aarch64")
                .appendingPathComponent("APKINDEX.tar.gz")
            var request = URLRequest(url: indexURL)
            request.httpMethod = "HEAD"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 5

            do {
                let (_, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<400).contains(httpResponse.statusCode) else {
                    return nil
                }
            } catch {
                return nil
            }
        }
        return max(1, Int((Date().timeIntervalSince(startedAt) * 1_000).rounded()))
    }
}

public struct LocalLinuxEnvironmentRecipe: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let summaryCommand: String
    public let displayedCommand: String
    public let command: String
    public let requiredPackages: Set<String>
    public let providedCommands: Set<String>
    public let mirror: LocalLinuxPackageMirror

    public init(
        id: String,
        title: String,
        detail: String,
        summaryCommand: String,
        displayedCommand: String,
        command: String,
        requiredPackages: Set<String>,
        providedCommands: Set<String>,
        mirror: LocalLinuxPackageMirror
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.summaryCommand = summaryCommand
        self.displayedCommand = displayedCommand
        self.command = command
        self.requiredPackages = requiredPackages
        self.providedCommands = providedCommands
        self.mirror = mirror
    }

    public var confirmationDetail: String {
        [
            detail,
            String(
                format: NSLocalizedString("下载源：%@", comment: "Local Linux recipe mirror"),
                mirror.displayName
            ),
            String(
                format: NSLocalizedString("命令：%@", comment: "Local Linux recipe exact command"),
                displayedCommand
            ),
            NSLocalizedString(
                "所选下载源只用于本次安装，不会修改 /etc/apk/repositories。",
                comment: "Local Linux recipe repository explanation"
            ),
            NSLocalizedString(
                "目标：本地 Linux RootFS。影响：软件包、依赖与 apk 缓存会持久增加 System 占用，直到你自行卸载或重置系统。",
                comment: "Local Linux recipe storage impact"
            ),
            NSLocalizedString(
                "安装终端会显示所用下载源与 apk 下载进度；如果网络长时间没有进展，可以中断后重新测速。",
                comment: "Local Linux recipe network progress explanation"
            )
        ].joined(separator: "\n\n")
    }

    /// 专用安装终端执行完 recipe 后立即退出，让 PTY 任务保留真实退出码。
    public var terminalInput: Data {
        Data("\(command); exit $?\n".utf8)
    }
}

public struct LocalLinuxEnvironmentInstallationResult: Equatable, Sendable {
    public let job: LocalLinuxJob
    public let output: String

    public init(job: LocalLinuxJob, output: String) {
        self.job = job
        self.output = output
    }

    /// `apk` 的退出码才是安装是否完成的依据，不能把“命令已结束”误报成安装成功。
    public var succeeded: Bool {
        job.state == .completed && job.exitCode == 0
    }
}

public enum LocalLinuxEnvironmentInstaller {
    public static func installedRecipeIDs() async -> Set<String> {
        guard let installedPackages = try? await LocalLinuxStorageManager.shared.installedPackageNames() else {
            return []
        }
        return Set(
            LocalLinuxEnvironmentRecipes.all.compactMap { recipe in
                recipe.requiredPackages.isSubset(of: installedPackages) ? recipe.id : nil
            }
        )
    }

    public static func startTerminal(columns: UInt16, rows: UInt16) async throws -> LocalLinuxJob {
        let workspace = try await LocalLinuxStorageManager.shared.interactiveUserWorkspace()
        return try await LocalLinuxJobScheduler.shared.startTerminal(
            context: nil,
            workspace: workspace,
            inputOwner: .user,
            columns: columns,
            rows: rows,
            // 安装命令由 App 固定为 POSIX 脚本，不跟随用户的交互 Shell 偏好。
            shellPathOverride: LocalLinuxTerminalShellConfiguration.defaultPath
        )
    }

    public static func waitForCompletion(jobID: UUID) async throws -> LocalLinuxEnvironmentInstallationResult {
        while let job = await LocalLinuxJobScheduler.shared.job(id: jobID) {
            if job.state.isTerminal {
                let output = (try? await LocalLinuxJobScheduler.shared.userVisibleOutput(jobID: job.id)) ?? ""
                return LocalLinuxEnvironmentInstallationResult(job: job, output: output)
            }
            try await Task<Never, Never>.sleep(nanoseconds: 250_000_000)
        }
        throw LocalLinuxRuntimeError.jobNotFound(jobID)
    }
}

public enum LocalLinuxEnvironmentRecipes {
    public static var all: [LocalLinuxEnvironmentRecipe] {
        all(using: LocalLinuxPackageMirrors.official)
    }

    public static func all(using mirror: LocalLinuxPackageMirror) -> [LocalLinuxEnvironmentRecipe] {
        [
            recipe(
                id: "bash",
                title: NSLocalizedString("安装 Bash", comment: "Bash environment recipe name"),
                detail: NSLocalizedString("从当前 Alpine 软件源安装 Bash；不会自动改用 Bash 执行失败的脚本。", comment: "Bash environment recipe detail"),
                packages: ["bash"],
                providedCommands: ["bash"],
                mirror: mirror
            ),
            recipe(
                id: "python",
                title: NSLocalizedString("安装 Python 环境", comment: "Python environment recipe name"),
                detail: NSLocalizedString("从当前 Alpine 软件源安装 python3 与 py3-pip。", comment: "Python environment recipe detail"),
                packages: ["python3", "py3-pip"],
                providedCommands: ["python", "python3", "pip", "pip3"],
                mirror: mirror
            ),
            recipe(
                id: "node",
                title: NSLocalizedString("安装 Node.js 环境", comment: "Node environment recipe name"),
                detail: NSLocalizedString("从当前 Alpine 软件源安装 nodejs 与 npm；npx 会随 npm 提供。", comment: "Node environment recipe detail"),
                packages: ["nodejs", "npm"],
                providedCommands: ["node", "npm", "npx"],
                mirror: mirror
            ),
            recipe(
                id: "build",
                title: NSLocalizedString("安装编译工具", comment: "Build tools environment recipe name"),
                detail: NSLocalizedString("安装 build-base 与 cmake；会明显增加系统占用和运行负载。", comment: "Build tools environment recipe detail"),
                packages: ["build-base", "cmake"],
                providedCommands: ["cc", "c++", "gcc", "g++", "make", "cmake"],
                mirror: mirror
            ),
            recipe(
                id: "uvx",
                title: NSLocalizedString("安装 uvx 环境", comment: "uvx environment recipe name"),
                detail: NSLocalizedString("从当前 Alpine 软件源安装 uv；之后由用户决定是否通过 uvx 下载并运行具体工具。", comment: "uvx environment recipe detail"),
                packages: ["uv"],
                providedCommands: ["uv", "uvx"],
                mirror: mirror
            )
        ]
    }

    private static func recipe(
        id: String,
        title: String,
        detail: String,
        packages: [String],
        providedCommands: Set<String>,
        mirror: LocalLinuxPackageMirror
    ) -> LocalLinuxEnvironmentRecipe {
        let summaryCommand = "apk add \(packages.joined(separator: " "))"
        let displayedCommand = copyableCommand(packages: packages, mirror: mirror)
        let script = installationScript(packages: packages, mirror: mirror)
        return LocalLinuxEnvironmentRecipe(
            id: id,
            title: title,
            detail: detail,
            summaryCommand: summaryCommand,
            displayedCommand: displayedCommand,
            command: encodedShellCommand(script: script),
            requiredPackages: Set(packages),
            providedCommands: providedCommands,
            mirror: mirror
        )
    }

    /// 推荐源只绑定到本次 apk 事务，不覆盖用户长期维护的 repositories 文件。
    static func installationScript(
        packages: [String],
        mirror: LocalLinuxPackageMirror = LocalLinuxPackageMirrors.official
    ) -> String {
        let selectedFormat = NSLocalizedString("使用软件源：%@", comment: "Linux recipe selected repository status")
        let selectedShellFormat = selectedFormat.replacingOccurrences(of: "%@", with: "%s")
        let installingFormat = NSLocalizedString("正在安装：%@", comment: "Linux recipe package installation status")
        let failureMessage = NSLocalizedString("安装未完成；如果下载长时间没有进展，请返回后重新测速或选择其他网络。", comment: "Linux recipe network failure advice")
        let packageList = packages.joined(separator: " ")
        let mirrorURL = mirror.baseURL.absoluteString

        return """
        #!/bin/sh
        set -u
        WORK_DIRECTORY="$(mktemp -d /tmp/etos-apk.XXXXXX)" || exit 1
        TEMP_REPOSITORIES="$WORK_DIRECTORY/repositories"
        cleanup() {
            rm -f "$TEMP_REPOSITORIES"
            rmdir "$WORK_DIRECTORY" 2>/dev/null || true
        }
        trap cleanup EXIT HUP INT TERM

        printf '\\033[2J\\033[H'
        BRANCH="v$(cut -d. -f1,2 /etc/alpine-release)"
        SELECTED_MIRROR=\(shellQuote(mirrorURL))
        printf '%s/%s/main\\n%s/%s/community\\n' "$SELECTED_MIRROR" "$BRANCH" "$SELECTED_MIRROR" "$BRANCH" > "$TEMP_REPOSITORIES"
        printf '[1/2] '
        printf \(shellQuote(selectedShellFormat + "\\n")) "$SELECTED_MIRROR"
        printf '[2/2] %s\\n' \(shellQuote(String(format: installingFormat, packageList)))
        apk --repositories-file "$TEMP_REPOSITORIES" --timeout 30 --progress add \(packages.map(shellQuote).joined(separator: " "))
        status=$?
        if [ "$status" -ne 0 ]; then
            printf '\\n%s\\n' \(shellQuote(failureMessage))
        fi
        exit "$status"
        """
    }

    private static func copyableCommand(
        packages: [String],
        mirror: LocalLinuxPackageMirror
    ) -> String {
        let mirrorURL = shellQuote(mirror.baseURL.absoluteString)
        let packageList = packages.map(shellQuote).joined(separator: " ")
        return "REPOSITORIES=\"$(mktemp /tmp/etos-apk.XXXXXX)\" && BRANCH=\"v$(cut -d. -f1,2 /etc/alpine-release)\" && printf '%s/%s/main\\n%s/%s/community\\n' \(mirrorURL) \"$BRANCH\" \(mirrorURL) \"$BRANCH\" > \"$REPOSITORIES\" && apk --repositories-file \"$REPOSITORIES\" --timeout 30 --progress add \(packageList); STATUS=$?; [ -z \"${REPOSITORIES:-}\" ] || rm -f \"$REPOSITORIES\"; (exit \"$STATUS\")"
    }

    private static func encodedShellCommand(script: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        return "printf '%s' '\(encoded)' | base64 -d | /bin/sh"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }

    public static func matching(command: String) -> LocalLinuxEnvironmentRecipe? {
        let name = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        return all.first { $0.providedCommands.contains(name) }
    }
}
