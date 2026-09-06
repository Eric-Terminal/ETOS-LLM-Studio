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

    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedRecipe: LocalLinuxEnvironmentRecipe?
    @State private var recipeStatuses: [String: RecipeStatus] = [:]
    @State private var activeRecipe: LocalLinuxEnvironmentRecipe?
    @State private var result: LocalLinuxEnvironmentInstallationResult?
    @State private var errorMessage: String?
    @State private var installationTerminalTarget: InstallationTerminalTarget?
    @State private var selectedMirror = LocalLinuxPackageMirrors.regionalFallback()
    @State private var selectedMirrorLatency: Int?
    @State private var isTestingMirrors = true
    @State private var mirrorProbeGeneration = 0
    @State private var recipes: [LocalLinuxEnvironmentRecipe] = []

    var body: some View {
        List {
            mirrorRecommendationSection
            ForEach(recipes) { recipe in
                Button {
                    selectedRecipe = recipe
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(recipe.title)
                            Text(recipe.summaryCommand).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        statusView(for: recipe)
                    }
                }
                .buttonStyle(.plain)
                .disabled(activeRecipe != nil || isTestingMirrors)
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
        .task {
            await refreshInstallationStatuses()
        }
        .task(id: mirrorProbeGeneration) {
            await refreshMirrorRecommendation()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshInstallationStatuses() }
        }
    }

    @ViewBuilder
    private var mirrorRecommendationSection: some View {
        Section {
            if isTestingMirrors {
                HStack {
                    ProgressView()
                    Text(NSLocalizedString("正在测试下载源…", comment: "Watch Linux mirror testing status"))
                }
            } else {
                Label(selectedMirror.displayName, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(selectedMirror.baseURL.absoluteString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if let selectedMirrorLatency {
                    Text(
                        String(
                            format: NSLocalizedString("检测耗时：%lld 毫秒", comment: "Watch Linux mirror probe latency"),
                            Int64(selectedMirrorLatency)
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else {
                    Text(NSLocalizedString("测速不可用，已按设备地区推荐。", comment: "Watch Linux mirror regional fallback explanation"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    mirrorProbeGeneration += 1
                } label: {
                    Label(NSLocalizedString("重新测速", comment: "Watch retest Linux mirrors"), systemImage: "arrow.clockwise")
                }
                .disabled(activeRecipe != nil)
            }
        } header: {
            Text(NSLocalizedString("推荐下载源", comment: "Watch recommended Linux mirror section"))
        } footer: {
            Text(NSLocalizedString("测速仅访问 Alpine 软件索引，不读取位置，也不修改系统软件源配置。", comment: "Watch Linux mirror recommendation explanation"))
        }
    }

    private func refreshMirrorRecommendation() async {
        isTestingMirrors = true
        let recommendation = await LocalLinuxPackageMirrors.recommend()
        let preparedRecipes = await Task.detached(priority: .userInitiated) {
            LocalLinuxEnvironmentRecipes.all(using: recommendation.selectedMirror)
        }.value
        guard !Task.isCancelled else { return }
        selectedMirror = recommendation.selectedMirror
        selectedMirrorLatency = recommendation.selectedLatencyMilliseconds
        recipes = preparedRecipes
        isTestingMirrors = false
        await refreshInstallationStatuses()
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
            await refreshInstallationStatuses()
        }
    }

    private func refreshInstallationStatuses() async {
        let installedIDs = await LocalLinuxEnvironmentInstaller.installedRecipeIDs()
        for recipe in recipes where activeRecipe?.id != recipe.id {
            if installedIDs.contains(recipe.id) {
                recipeStatuses[recipe.id] = .installed
            } else if recipeStatuses[recipe.id] == .installed {
                recipeStatuses[recipe.id] = nil
            }
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
