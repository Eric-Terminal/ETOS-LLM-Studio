import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacLinuxRecipePresentationTests {
    @Test("安装目录固定下载源与确认命令，向导仅有配方身份和状态")
    func catalogAndGuideBoundaries() {
        let recommendation = LocalLinuxMirrorRecommendation(selectedMirror: LocalLinuxPackageMirrors.official, probeResults: [])
        let job = makeJob()
        let catalog = MacLinuxRecipeCatalog.prepare(recommendation: recommendation, installed: ["bash"], attemptID: "python", job: job)
        #expect(catalog.rows.count == 5)
        #expect(catalog.rows.first { $0.id == "python" }?.isInstalling == true)
        #expect(catalog.rows.first { $0.id == "bash" }?.status != nil)
        #expect(catalog.rows.allSatisfy { $0.confirmation.contains(LocalLinuxPackageMirrors.official.baseURL.absoluteString) })
        guard case .dictionary(let fields) = catalog.guide, case .array(let recipes)? = fields["recipes"], case .dictionary(let row)? = recipes.first else {
            Issue.record("缺少安装目录快照"); return
        }
        #expect(Set(fields.keys) == ["mirror_id", "measured", "recipes"])
        #expect(Set(row.keys) == ["id", "installed", "running"])
    }

    @Test("安装结果保留真实退出码，不把非零退出当成功")
    func resultsUseExitStatus() {
        var job = makeJob(); job.state = .completed; job.exitCode = 0
        let success = MacLinuxRecipeResult.prepare(job: job, output: "成功输出")
        job.exitCode = 7
        let failure = MacLinuxRecipeResult.prepare(job: job, output: "失败输出")
        #expect(success.exitCode == "0"); #expect(failure.exitCode == "7")
        #expect(success.state != failure.state); #expect(failure.output == "失败输出")
    }

    @Test("合规目录覆盖共享枚举中的八份文件，ID 保持随包资源名")
    func complianceCatalogKeepsResourceIdentity() {
        let rows = MacLinuxComplianceRow.prepare()
        #expect(rows.count == 8)
        #expect(rows.map(\.id) == LocalLinuxComplianceDocument.allCases.map(\.rawValue))
        #expect(rows.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
        #expect(rows.contains { $0.document == .sourceOffer }); #expect(rows.contains { $0.document == .sbom })
    }

    private func makeJob() -> LocalLinuxJob {
        LocalLinuxJob(requestID: 1, kind: .terminal, sessionID: nil, runID: nil, rootRunID: nil, parentRunID: nil,
            toolCallID: nil, workspaceID: nil, executorDeviceID: "test", request: LocalLinuxJobRequest(executable: "/bin/sh", arguments: ["/bin/sh"]), state: .running)
    }
}
