import Foundation
import Testing
@testable import ETOSCore

struct LocalLinuxWorkspaceRemovalTests {
    private enum Failure: Error { case database }

    @Test("缺失的工作区目录不会导出成空归档")
    func missingWorkspaceDoesNotCreateArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalLinuxStorageManager(documentsDirectory: root, appGroupLayout: nil)
        let workspace = LocalAgentWorkspace(sessionID: nil, guestPath: "/mnt/workspaces/missing", hostRelativePath: "Workspaces/missing")
        do {
            _ = try await storage.exportWorkspace(workspace)
            Issue.record("缺失目录不能报告导出成功")
        } catch {
            #expect(!FileManager.default.fileExists(atPath: storage.layout.exports.path))
        }
    }

    @Test("删除记录失败会恢复工作区内容及目录名")
    func databaseFailureRestoresFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = workspace.appendingPathComponent("result.txt"), data = Data("需要保留的结果".utf8)
        try data.write(to: file)
        #expect(throws: Failure.self) {
            try LocalLinuxStorageManager.removeWorkspaceDirectory(workspace, fileManager: .default) {
                #expect(!FileManager.default.fileExists(atPath: workspace.path))
                throw Failure.database
            }
        }
        #expect(try Data(contentsOf: file) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["workspace"])
    }

    @Test("删除成功后清理暂存目录，保留相邻文件")
    func successfulRemovalKeepsNeighbours() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let neighbour = root.appendingPathComponent("keep.txt"), data = Data("相邻文件".utf8)
        try data.write(to: neighbour)
        var deleted = false
        try LocalLinuxStorageManager.removeWorkspaceDirectory(workspace, fileManager: .default) { deleted = true }
        #expect(deleted)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["keep.txt"])
        #expect(try Data(contentsOf: neighbour) == data)
    }

    @Test("文件目录已经缺失仍可清理记录")
    func absentDirectoryStillDeletesRecord() throws {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var deleted = false
        try LocalLinuxStorageManager.removeWorkspaceDirectory(absent, fileManager: .default) { deleted = true }
        #expect(deleted)
        #expect(!FileManager.default.fileExists(atPath: absent.path))
    }
}
