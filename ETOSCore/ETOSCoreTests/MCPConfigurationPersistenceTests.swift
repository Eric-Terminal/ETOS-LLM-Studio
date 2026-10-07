import Foundation
import Testing
@testable import ETOSCore

@Suite("MCP 后台配置保存", .serialized)
struct MCPConfigurationPersistenceTests {
    @Test("旧编辑草稿和已删除配置不能覆盖数据库新状态")
    func staleDraftIsRejected() async throws {
        let worker = MCPConfigurationPersistenceWorker(appToolDefaults: [])
        let draft = MCPServerConfiguration(displayName: "后台保存回归", transport: .localStdio(configuration: .init(command: "/bin/cat")))
        defer { MCPServerStore.delete(draft) }
        let created = try await worker.save(draft, replacing: nil)
        let original = try #require(created.snapshot.servers.first { $0.id == draft.id })
        var edited = original
        edited.displayName = "其他窗口已更新"
        let saved = try await worker.save(edited, replacing: original)
        #expect(saved.revision > created.revision)

        do {
            _ = try await worker.save(original, replacing: original)
            Issue.record("旧草稿不应保存成功")
        } catch {
            #expect(error as? MCPConfigurationWriteError == .changedExternally)
        }
        #expect(MCPServerStore.loadServers().first { $0.id == draft.id } == edited)
        _ = try await worker.delete(edited)
        do {
            _ = try await worker.save(original, replacing: original)
            Issue.record("已删除配置不应被旧编辑器重新创建")
        } catch {
            #expect(error as? MCPConfigurationWriteError == .changedExternally)
        }
    }

    @Test("更换连接会清除旧工具目录，仅修改名称则保留目录和排序")
    func transportChangeInvalidatesMetadata() async throws {
        let worker = MCPConfigurationPersistenceWorker(appToolDefaults: [])
        let draft = MCPServerConfiguration(displayName: "元数据保存回归", transport: .localStdio(configuration: .init(command: "/bin/cat")))
        defer { MCPServerStore.delete(draft) }
        let created = try await worker.save(draft, replacing: nil)
        let original = try #require(created.snapshot.servers.first { $0.id == draft.id })
        let metadata = MCPServerMetadataCache(
            info: nil, tools: [.init(toolId: "old_tool", description: nil, inputSchema: nil, examples: nil)],
            resources: [], resourceTemplates: [], prompts: [], roots: []
        )
        MCPServerStore.saveMetadata(metadata, for: draft.id)
        var renamed = original
        renamed.displayName = "名称已更新"
        let renameResult = try await worker.save(renamed, replacing: original)
        #expect(renameResult.snapshot.metadata[draft.id] == metadata)
        #expect(renameResult.snapshot.servers.first { $0.id == draft.id }?.sortIndex == original.sortIndex)
        var changed = renamed
        changed.transport = .localStdio(configuration: .init(command: "/usr/bin/env", arguments: ["node", "server.js"]))
        let changeResult = try await worker.save(changed, replacing: renamed)
        #expect(changeResult.snapshot.metadata[draft.id] == nil)
        #expect(MCPServerStore.loadMetadata(for: draft.id) == nil)
    }
}
