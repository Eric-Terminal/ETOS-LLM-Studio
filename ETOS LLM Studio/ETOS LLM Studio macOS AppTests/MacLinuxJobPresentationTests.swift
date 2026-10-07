import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacLinuxJobPresentationTests {
    @Test("任务分组去重并优先保留最新活跃状态，不受历史分页上限影响")
    func catalogKeepsActiveJobsAndCompletion() throws {
        let sessionID = UUID(), runID = UUID()
        let active = makeJob(sessionID: sessionID, runID: runID, state: .running)
        var stale = active; stale.state = .queued
        let finished = makeJob(sessionID: sessionID, runID: runID, state: .completed)
        let standalone = makeJob(sessionID: nil, runID: nil, state: .running)
        let catalog = MacLinuxJobCatalog.prepare(active: [active, standalone], history: [stale, finished, finished], watched: [], hasMore: true, sessionID: nil)
        #expect(catalog.groups.count == 2)
        #expect(catalog.activeCount == 2 && catalog.historyCount == 1 && catalog.hasMore)
        let agent = try #require(catalog.groups.first { $0.runID == runID })
        #expect(agent.hasActiveJobs)
        #expect(agent.rows.count == 2)
        #expect(agent.rows.first { $0.id == active.id }?.job.state == .running)
        let ended = MacLinuxJobCatalog.prepare(active: [], history: [], watched: [finished], hasMore: true, sessionID: sessionID)
        #expect(ended.historyCount == 1 && ended.activeCount == 0)
        #expect(ended.groups.first?.hasActiveJobs == false)
    }

    @Test("任务向导目录不读取命令、参数、目录、环境值或输出路径")
    func guideCatalogContainsOnlyIdentityAndState() throws {
        let job = makeJob(sessionID: UUID(), runID: UUID(), state: .running)
        let catalog = MacLinuxJobCatalog.prepare(active: [job], history: [], watched: [], hasMore: false, sessionID: nil)
        guard case .array(let rows) = catalog.guideRows, case .dictionary(let fields)? = rows.first else {
            Issue.record("缺少任务向导目录"); return
        }
        #expect(Set(fields.keys) == ["id", "kind", "state", "session_id", "run_id"])
        #expect(fields["id"] == .string(job.id.uuidString))
        #expect(fields["state"] == .string("running"))
    }

    @Test("任务参数展示保留逐项边界和特殊字符，不展开环境变量")
    func requestDetailsPreserveLiteralArguments() throws {
        var job = makeJob(sessionID: nil, runID: nil, state: .completed)
        job.request.arguments = ["space inside", "line\nbreak", "\"quoted\"", "$TOKEN"]
        let details = try MacLinuxJobDetails.prepare(job)
        let json = try #require(details.fields.first { $0.id == "arguments" }?.value)
        #expect(try JSONDecoder().decode([String].self, from: Data(json.utf8)) == job.request.arguments)
        #expect(!details.fields.contains { $0.value.contains("private-environment-secret") })
        #expect(details.job.request.environment["TOKEN"] == "private-environment-secret")
    }

    private func makeJob(sessionID: UUID?, runID: UUID?, state: LocalLinuxJobState) -> LocalLinuxJob {
        LocalLinuxJob(requestID: 1, kind: .shell, sessionID: sessionID, runID: runID, rootRunID: runID, parentRunID: nil,
            toolCallID: "private-tool-call", workspaceID: UUID(), executorDeviceID: "test",
            request: LocalLinuxJobRequest(executable: "/private/tool", arguments: ["private-argument"],
                environment: ["TOKEN": "private-environment-secret"], workingDirectory: "/private/work", shellScript: "private-script"), state: state)
    }
}
