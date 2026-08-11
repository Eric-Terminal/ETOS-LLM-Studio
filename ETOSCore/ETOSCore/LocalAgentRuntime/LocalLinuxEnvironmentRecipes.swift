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
    public let command: String
    public let providedCommands: Set<String>

    public init(
        id: String,
        title: String,
        detail: String,
        command: String,
        providedCommands: Set<String>
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.command = command
        self.providedCommands = providedCommands
    }

    public var confirmationDetail: String {
        [
            detail,
            String(
                format: NSLocalizedString("命令：%@", comment: "Local Linux recipe exact command"),
                command
            ),
            NSLocalizedString(
                "内置初始软件源：https://dl-cdn.alpinelinux.org/alpine/v3.24/main 与 community；若你已修改 /etc/apk/repositories，执行时以当前文件为准。",
                comment: "Local Linux recipe repository explanation"
            ),
            NSLocalizedString(
                "目标：本地 Linux RootFS。影响：软件包、依赖与 apk 缓存会持久增加 System 占用，直到你自行卸载或重置系统。",
                comment: "Local Linux recipe storage impact"
            ),
            NSLocalizedString(
                "安装终端会显示 apk 下载进度；网络连续 120 秒没有传输进展时，apk 才会停止并报告错误。",
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
    public static var all: [LocalLinuxEnvironmentRecipe] {
        [
            LocalLinuxEnvironmentRecipe(
                id: "bash",
                title: NSLocalizedString("安装 Bash", comment: "Bash environment recipe name"),
                detail: NSLocalizedString("从当前 Alpine 软件源安装 Bash；不会自动改用 Bash 执行失败的脚本。", comment: "Bash environment recipe detail"),
                command: "apk --timeout 120 --progress add bash",
                providedCommands: ["bash"]
            ),
            LocalLinuxEnvironmentRecipe(
                id: "python",
                title: NSLocalizedString("安装 Python 环境", comment: "Python environment recipe name"),
                detail: NSLocalizedString("从当前 Alpine 软件源安装 python3 与 py3-pip。", comment: "Python environment recipe detail"),
                command: "apk --timeout 120 --progress add python3 py3-pip",
                providedCommands: ["python", "python3", "pip", "pip3"]
            ),
            LocalLinuxEnvironmentRecipe(
                id: "node",
                title: NSLocalizedString("安装 Node.js 环境", comment: "Node environment recipe name"),
                detail: NSLocalizedString("从当前 Alpine 软件源安装 nodejs 与 npm；npx 会随 npm 提供。", comment: "Node environment recipe detail"),
                command: "apk --timeout 120 --progress add nodejs npm",
                providedCommands: ["node", "npm", "npx"]
            ),
            LocalLinuxEnvironmentRecipe(
                id: "build",
                title: NSLocalizedString("安装编译工具", comment: "Build tools environment recipe name"),
                detail: NSLocalizedString("安装 build-base 与 cmake；会明显增加系统占用和运行负载。", comment: "Build tools environment recipe detail"),
                command: "apk --timeout 120 --progress add build-base cmake",
                providedCommands: ["cc", "c++", "gcc", "g++", "make", "cmake"]
            ),
            LocalLinuxEnvironmentRecipe(
                id: "uvx",
                title: NSLocalizedString("安装 uvx 环境", comment: "uvx environment recipe name"),
                detail: NSLocalizedString("从当前 Alpine 软件源安装 uv；之后由用户决定是否通过 uvx 下载并运行具体工具。", comment: "uvx environment recipe detail"),
                command: "apk --timeout 120 --progress add uv",
                providedCommands: ["uv", "uvx"]
            )
        ]
    }

    public static func matching(command: String) -> LocalLinuxEnvironmentRecipe? {
        let name = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        return all.first { $0.providedCommands.contains(name) }
    }
}
