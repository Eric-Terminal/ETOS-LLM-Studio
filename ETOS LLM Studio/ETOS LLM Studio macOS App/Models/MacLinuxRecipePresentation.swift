import ETOSCore
import Foundation

struct MacLinuxRecipeRow: Identifiable, Sendable {
    let recipe: LocalLinuxEnvironmentRecipe
    let confirmation: String
    let status: String?
    let isInstalling: Bool
    var id: String { recipe.id }
}

struct MacLinuxRecipeCatalog: Sendable {
    let id = UUID()
    let rows: [MacLinuxRecipeRow]
    let mirrorName: String
    let mirrorURL: String
    let latency: String
    let measured: Bool
    let guide: JSONValue

    static func prepare(recommendation: LocalLinuxMirrorRecommendation, installed: Set<String>, attemptID: String?, job: LocalLinuxJob?) -> Self {
        let recipes = LocalLinuxEnvironmentRecipes.all(using: recommendation.selectedMirror)
        let rows = recipes.map { recipe in
            let running = attemptID == recipe.id && job.map { !$0.state.isTerminal } == true
            let status: String?
            if running { status = NSLocalizedString("正在安装", comment: "") }
            else if installed.contains(recipe.id) { status = NSLocalizedString("已安装", comment: "") }
            else if attemptID == recipe.id, let job, job.state.isTerminal { status = MacLinuxRecipeResult.prepare(job: job, output: "").state }
            else { status = nil }
            return MacLinuxRecipeRow(recipe: recipe, confirmation: recipe.confirmationDetail, status: status, isInstalling: running)
        }
        let latency = recommendation.selectedLatencyMilliseconds.map {
            String(format: NSLocalizedString("检测耗时：%lld 毫秒", comment: ""), Int64($0))
        } ?? NSLocalizedString("测速不可用，已按设备地区推荐。", comment: "")
        return Self(rows: rows, mirrorName: recommendation.selectedMirror.displayName, mirrorURL: recommendation.selectedMirror.baseURL.absoluteString,
            latency: latency, measured: recommendation.isMeasured, guide: .dictionary([
                "mirror_id": .string(recommendation.selectedMirror.id), "measured": .bool(recommendation.isMeasured),
                "recipes": .array(rows.map { .dictionary(["id": .string($0.id), "installed": .bool(installed.contains($0.id)), "running": .bool($0.isInstalling)]) })
            ]))
    }
}

struct MacLinuxRecipeConfirmation: Identifiable, Sendable {
    let id = UUID()
    let row: MacLinuxRecipeRow
    let lease: UUID
    let catalogID: UUID
    let revision: UUID
}

struct MacLinuxRecipeTerminalTarget: Identifiable {
    let id: UUID
}

struct MacLinuxRecipeResult: Sendable {
    let job: LocalLinuxJob
    let state: String
    let exitCode: String
    let output: String
    static func prepare(job: LocalLinuxJob, output: String) -> Self {
        let succeeded = LocalLinuxEnvironmentInstallationResult(job: job, output: output).succeeded
        let state = succeeded ? NSLocalizedString("命令已成功执行。", comment: "")
            : job.state == .completed ? NSLocalizedString("失败", comment: "") : job.state.displayName
        return Self(job: job, state: state,
            exitCode: job.exitCode.map { String($0) } ?? NSLocalizedString("无", comment: ""), output: output)
    }
}
