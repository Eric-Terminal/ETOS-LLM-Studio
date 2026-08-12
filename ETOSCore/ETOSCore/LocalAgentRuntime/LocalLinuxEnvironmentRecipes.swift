// ============================================================================
// LocalLinuxEnvironmentRecipes.swift
// ============================================================================
// ETOS LLM Studio
//
// 这些命令随 App 版本固定并由用户主动执行。运行时、MCP 或 Skill 只可以提示，
// 不能自行触发安装或切换软件源。
// ============================================================================

import Foundation

public struct LocalLinuxEnvironmentRecipe: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let displayedCommand: String
    public let command: String
    public let providedCommands: Set<String>

    public init(
        id: String,
        title: String,
        detail: String,
        displayedCommand: String,
        command: String,
        providedCommands: Set<String>
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.displayedCommand = displayedCommand
        self.command = command
        self.providedCommands = providedCommands
    }

    public var confirmationDetail: String {
        [
            detail,
            String(
                format: NSLocalizedString("命令：%@", comment: "Local Linux recipe exact command"),
                displayedCommand
            ),
            NSLocalizedString(
                "使用内置初始源时，执行前会临时测试可用镜像；若你已修改 /etc/apk/repositories，则保持当前配置不变。",
                comment: "Local Linux recipe repository explanation"
            ),
            NSLocalizedString(
                "目标：本地 Linux RootFS。影响：软件包、依赖与 apk 缓存会持久增加 System 占用，直到你自行卸载或重置系统。",
                comment: "Local Linux recipe storage impact"
            ),
            NSLocalizedString(
                "安装终端会显示测速结果与 apk 下载进度；如果网络长时间没有进展，可以中断后重试或手动更换软件源。",
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
    public static func startTerminal(columns: UInt16, rows: UInt16) async throws -> LocalLinuxJob {
        let workspace = try await LocalLinuxStorageManager.shared.interactiveUserWorkspace()
        return try await LocalLinuxJobScheduler.shared.startTerminal(
            context: nil,
            workspace: workspace,
            inputOwner: .user,
            columns: columns,
            rows: rows
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
    private static let defaultMirror = "https://dl-cdn.alpinelinux.org/alpine"
    private static let mirrorCandidates = [
        defaultMirror,
        "https://mirrors.tuna.tsinghua.edu.cn/alpine",
        "https://mirrors.ustc.edu.cn/alpine",
        "https://mirror.nju.edu.cn/alpine"
    ]

    public static var all: [LocalLinuxEnvironmentRecipe] {
        [
            recipe(
                id: "bash",
                title: NSLocalizedString("安装 Bash", comment: "Bash environment recipe name"),
                detail: NSLocalizedString("从当前 Alpine 软件源安装 Bash；不会自动改用 Bash 执行失败的脚本。", comment: "Bash environment recipe detail"),
                packages: ["bash"],
                providedCommands: ["bash"]
            ),
            recipe(
                id: "python",
                title: NSLocalizedString("安装 Python 环境", comment: "Python environment recipe name"),
                detail: NSLocalizedString("从当前 Alpine 软件源安装 python3 与 py3-pip。", comment: "Python environment recipe detail"),
                packages: ["python3", "py3-pip"],
                providedCommands: ["python", "python3", "pip", "pip3"]
            ),
            recipe(
                id: "node",
                title: NSLocalizedString("安装 Node.js 环境", comment: "Node environment recipe name"),
                detail: NSLocalizedString("从当前 Alpine 软件源安装 nodejs 与 npm；npx 会随 npm 提供。", comment: "Node environment recipe detail"),
                packages: ["nodejs", "npm"],
                providedCommands: ["node", "npm", "npx"]
            ),
            recipe(
                id: "build",
                title: NSLocalizedString("安装编译工具", comment: "Build tools environment recipe name"),
                detail: NSLocalizedString("安装 build-base 与 cmake；会明显增加系统占用和运行负载。", comment: "Build tools environment recipe detail"),
                packages: ["build-base", "cmake"],
                providedCommands: ["cc", "c++", "gcc", "g++", "make", "cmake"]
            ),
            recipe(
                id: "uvx",
                title: NSLocalizedString("安装 uvx 环境", comment: "uvx environment recipe name"),
                detail: NSLocalizedString("从当前 Alpine 软件源安装 uv；之后由用户决定是否通过 uvx 下载并运行具体工具。", comment: "uvx environment recipe detail"),
                packages: ["uv"],
                providedCommands: ["uv", "uvx"]
            )
        ]
    }

    private static func recipe(
        id: String,
        title: String,
        detail: String,
        packages: [String],
        providedCommands: Set<String>
    ) -> LocalLinuxEnvironmentRecipe {
        let displayedCommand = "apk add \(packages.joined(separator: " "))"
        let script = installationScript(packages: packages)
        return LocalLinuxEnvironmentRecipe(
            id: id,
            title: title,
            detail: detail,
            displayedCommand: displayedCommand,
            command: encodedShellCommand(script: script),
            providedCommands: providedCommands
        )
    }

    /// 只有 RootFS 仍使用内置默认源时才自动测速，避免覆盖用户的仓库选择。
    static func installationScript(packages: [String]) -> String {
        let checkingMessage = NSLocalizedString("正在检测可用的 Alpine 软件源…", comment: "Linux recipe mirror checking status")
        let customMessage = NSLocalizedString("检测到自定义软件源，保持当前配置。", comment: "Linux recipe custom repository status")
        let fallbackMessage = NSLocalizedString("没有镜像在限定时间内完成测速，继续使用内置软件源。", comment: "Linux recipe mirror fallback status")
        let selectedFormat = NSLocalizedString("使用软件源：%@", comment: "Linux recipe selected repository status")
        let selectedShellFormat = selectedFormat.replacingOccurrences(of: "%@", with: "%s")
        let installingFormat = NSLocalizedString("正在安装：%@", comment: "Linux recipe package installation status")
        let failureMessage = NSLocalizedString("安装未完成；如果下载长时间没有进展，请重试或在 /etc/apk/repositories 中更换软件源。", comment: "Linux recipe network failure advice")
        let packageList = packages.joined(separator: " ")
        let candidates = mirrorCandidates.map(shellQuote).joined(separator: " ")

        return """
        #!/bin/sh
        set -u
        DEFAULT_MIRROR=\(shellQuote(defaultMirror))
        WORK_DIRECTORY="$(mktemp -d /tmp/etos-apk.XXXXXX)" || exit 1
        TEMP_REPOSITORIES="$WORK_DIRECTORY/repositories"
        FASTEST_MIRROR="$WORK_DIRECTORY/fastest-mirror"
        cleanup() {
            rm -f "$TEMP_REPOSITORIES" "$FASTEST_MIRROR"
            rmdir "$WORK_DIRECTORY" 2>/dev/null || true
        }
        trap cleanup EXIT HUP INT TERM

        printf '\\033[2J\\033[H'
        BRANCH="v$(cut -d. -f1,2 /etc/alpine-release)"
        ARCH="$(apk --print-arch)"
        CURRENT_REPOSITORIES="$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' -e 's:/*$::' /etc/apk/repositories 2>/dev/null)"
        DEFAULT_REPOSITORIES="$(printf '%s\\n%s' "$DEFAULT_MIRROR/$BRANCH/main" "$DEFAULT_MIRROR/$BRANCH/community")"
        REPOSITORIES_FILE=

        if [ "$CURRENT_REPOSITORIES" = "$DEFAULT_REPOSITORIES" ]; then
            printf '[1/3] %s\\n' \(shellQuote(checkingMessage))
            probe_mirror() {
                mirror="$1"
                main_bytes="$(timeout 8 sh -c 'wget -q -T 4 -O - "$1" 2>/dev/null | head -c 131072 | wc -c' sh "$mirror/$BRANCH/main/$ARCH/APKINDEX.tar.gz")"
                [ "${main_bytes:-0}" -ge 131072 ] 2>/dev/null || return
                community_bytes="$(timeout 8 sh -c 'wget -q -T 4 -O - "$1" 2>/dev/null | head -c 131072 | wc -c' sh "$mirror/$BRANCH/community/$ARCH/APKINDEX.tar.gz")"
                [ "${community_bytes:-0}" -ge 131072 ] 2>/dev/null || return
                (set -C; printf '%s\\n' "$mirror" > "$FASTEST_MIRROR") 2>/dev/null || true
            }

            rm -f "$FASTEST_MIRROR"
            probe_pids=
            for mirror in \(candidates); do
                probe_mirror "$mirror" &
                probe_pids="$probe_pids $!"
            done
            for probe_pid in $probe_pids; do
                wait "$probe_pid" 2>/dev/null || true
            done

            if [ -s "$FASTEST_MIRROR" ]; then
                SELECTED_MIRROR="$(head -n 1 "$FASTEST_MIRROR")"
            else
                SELECTED_MIRROR="$DEFAULT_MIRROR"
                printf '[2/3] %s\\n' \(shellQuote(fallbackMessage))
            fi
            printf '%s/%s/main\\n%s/%s/community\\n' "$SELECTED_MIRROR" "$BRANCH" "$SELECTED_MIRROR" "$BRANCH" > "$TEMP_REPOSITORIES"
            REPOSITORIES_FILE="$TEMP_REPOSITORIES"
            printf '[2/3] '
            printf \(shellQuote(selectedShellFormat + "\\n")) "$SELECTED_MIRROR"
        else
            printf '[1/3] %s\\n' \(shellQuote(customMessage))
            printf '[2/3] %s\\n' \(shellQuote(String(format: selectedFormat, "/etc/apk/repositories")))
        fi

        printf '[3/3] %s\\n' \(shellQuote(String(format: installingFormat, packageList)))
        if [ -n "$REPOSITORIES_FILE" ]; then
            apk --repositories-file "$REPOSITORIES_FILE" --timeout 30 --progress add \(packages.map(shellQuote).joined(separator: " "))
        else
            apk --timeout 30 --progress add \(packages.map(shellQuote).joined(separator: " "))
        fi
        status=$?
        if [ "$status" -ne 0 ]; then
            printf '\\n%s\\n' \(shellQuote(failureMessage))
        fi
        exit "$status"
        """
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
