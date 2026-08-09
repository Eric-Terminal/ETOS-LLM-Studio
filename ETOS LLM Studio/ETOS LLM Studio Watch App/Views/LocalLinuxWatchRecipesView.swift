// watchOS 用户主动执行的 Linux 环境安装 recipe。
import ETOSCore
import SwiftUI

struct LocalLinuxWatchRecipesView: View {
    @State private var selectedRecipe: LocalLinuxEnvironmentRecipe?
    @State private var result = ""

    var body: some View {
        List {
            ForEach(LocalLinuxEnvironmentRecipes.all) { recipe in
                Button {
                    selectedRecipe = recipe
                } label: {
                    VStack(alignment: .leading) {
                        Text(recipe.title)
                        Text(recipe.command).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            if !result.isEmpty {
                Text(result).font(.caption2.monospaced())
            }
            Text(NSLocalizedString("默认不会安装任何软件；选择后会显示并确认准确命令。", comment: "Watch Linux recipes footer"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(NSLocalizedString("常用环境", comment: "Watch Linux recipes title"))
        .confirmationDialog(selectedRecipe?.title ?? "", isPresented: Binding(get: { selectedRecipe != nil }, set: { if !$0 { selectedRecipe = nil } })) {
            Button(NSLocalizedString("执行", comment: "Execute")) {
                if let selectedRecipe { run(selectedRecipe) }
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(selectedRecipe?.confirmationDetail ?? "")
        }
    }

    private func run(_ recipe: LocalLinuxEnvironmentRecipe) {
        selectedRecipe = nil
        Task {
            do {
                let workspace = try await LocalLinuxStorageManager.shared.interactiveUserWorkspace()
                let executable = "/bin/sh"
                let request = LocalLinuxJobRequest(
                    executable: executable,
                    arguments: [executable, "-lc", recipe.command],
                    workingDirectory: workspace.guestPath,
                    timeoutSeconds: 0,
                    outputLimitBytes: 0,
                    shellScript: recipe.command
                )
                let match = await LocalLinuxApprovalPolicy.shared.evaluate(
                    request: request,
                    kind: .recipe,
                    isEnabled: AppConfigStore.boolValue(for: .localLinuxCommandSafetyEnabled)
                )
                let approvedRuleIDs: Set<UUID>
                if let match, match.action == .confirm {
                    approvedRuleIDs = [match.ruleID]
                } else {
                    approvedRuleIDs = []
                }
                let job = try await LocalLinuxJobScheduler.shared.runCommand(
                    kind: .recipe,
                    request: request,
                    context: nil,
                    workspace: workspace,
                    approval: LocalLinuxCommandApproval(approvedRuleIDs: approvedRuleIDs)
                )
                result = (try? await LocalLinuxJobScheduler.shared.userVisibleOutput(jobID: job.id)) ?? job.state.rawValue
            } catch { result = error.localizedDescription }
        }
    }
}
