// watchOS 用户主动执行的 Linux 环境安装 recipe。
import ETOSCore
import SwiftUI

struct LocalLinuxWatchRecipesView: View {
    private struct InstallationTerminalTarget: Identifiable, Hashable {
        let recipe: LocalLinuxEnvironmentRecipe
        let jobID: UUID

        var id: UUID { jobID }
    }

    private enum RecipeStatus {
        case running
        case installed
        case failed
    }

    @State private var selectedRecipe: LocalLinuxEnvironmentRecipe?
    @State private var recipeStatuses: [String: RecipeStatus] = [:]
    @State private var activeRecipe: LocalLinuxEnvironmentRecipe?
    @State private var result: LocalLinuxEnvironmentInstallationResult?
    @State private var errorMessage: String?
    @State private var installationTerminalTarget: InstallationTerminalTarget?

    var body: some View {
        List {
            ForEach(LocalLinuxEnvironmentRecipes.all) { recipe in
                Button {
                    selectedRecipe = recipe
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(recipe.title)
                            Text(recipe.displayedCommand).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        statusView(for: recipe)
                    }
                }
                .buttonStyle(.plain)
                .disabled(activeRecipe != nil)
            }
            if let activeRecipe {
                Section(activeRecipe.title) {
                    HStack {
                        ProgressView()
                        Text(NSLocalizedString("正在安装", comment: "Watch Linux recipe installing status"))
                    }
                }
            } else if let result {
                Section(NSLocalizedString("最近结果", comment: "Watch Linux recipe result")) {
                    Label(
                        result.succeeded
                            ? NSLocalizedString("已安装", comment: "Watch Linux recipe installed status")
                            : NSLocalizedString("失败", comment: "Watch Linux recipe failed status"),
                        systemImage: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(result.succeeded ? .green : .red)
                    if let exitCode = result.job.exitCode {
                        LabeledContent(NSLocalizedString("退出码", comment: "Watch Linux recipe exit code"), value: "\(exitCode)")
                    }
                    Text(
                        result.output.isEmpty
                            ? (result.succeeded
                                ? NSLocalizedString("命令已成功执行。", comment: "Watch Linux recipe succeeded without output")
                                : result.job.state.displayName)
                            : result.output
                    )
                    .font(.caption2.monospaced())
                }
            } else if let errorMessage {
                Section(NSLocalizedString("最近结果", comment: "Watch Linux recipe result")) {
                    Label(NSLocalizedString("失败", comment: "Watch Linux recipe failed status"), systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage).font(.caption2.monospaced())
                }
            }
            Text(NSLocalizedString("默认不会安装任何软件；选择后会显示并确认准确命令。", comment: "Watch Linux recipes footer"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(NSLocalizedString("常用环境", comment: "Watch Linux recipes title"))
        .navigationDestination(item: $installationTerminalTarget) { target in
            LocalLinuxWatchTerminalView(
                initialJobID: target.jobID,
                showsTerminalManagement: false,
                startupInput: target.recipe.terminalInput,
                title: target.recipe.title
            )
        }
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
        activeRecipe = recipe
        result = nil
        errorMessage = nil
        recipeStatuses[recipe.id] = .running
        Task {
            do {
                let terminal = try await LocalLinuxEnvironmentInstaller.startTerminal(columns: 40, rows: 12)
                installationTerminalTarget = InstallationTerminalTarget(recipe: recipe, jobID: terminal.id)
                let installation = try await LocalLinuxEnvironmentInstaller.waitForCompletion(jobID: terminal.id)
                result = installation
                recipeStatuses[recipe.id] = installation.succeeded ? .installed : .failed
            } catch {
                errorMessage = error.localizedDescription
                recipeStatuses[recipe.id] = .failed
            }
            activeRecipe = nil
        }
    }

    @ViewBuilder
    private func statusView(for recipe: LocalLinuxEnvironmentRecipe) -> some View {
        switch recipeStatuses[recipe.id] {
        case .running:
            ProgressView()
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }
}
