import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacSessionLibrarySnapshotTests {
    @Test("嵌套路径保留父级，文件夹计数只包含直接会话，隐藏子代理不泄露到列表")
    func folderPathsAndDirectMembership() throws {
        let parent = SessionFolder(name: "项目")
        let child = SessionFolder(name: "资料", parentID: parent.id)
        let direct = ChatSession(id: UUID(), name: "讨论", folderID: parent.id)
        let nested = ChatSession(id: UUID(), name: "细节", folderID: child.id)
        let hidden = ChatSession(id: UUID(), name: "后台任务", folderID: parent.id, containerSessionID: direct.id)
        let snapshot = MacSessionLibrarySnapshot.prepare(
            sessions: [direct, nested, hidden], folders: [parent, child], tags: [], scope: .folder(parent.id), query: ""
        ) { _ in Issue.record("无搜索词时不应读消息文件"); return [] }
        #expect(snapshot.allCount == 2)
        #expect(snapshot.sessions.map(\.id) == [direct.id])
        #expect(snapshot.folders.first(where: { $0.id == parent.id })?.count == 1)
        let row = try #require(snapshot.folders.first(where: { $0.id == child.id }))
        #expect(row.path == "项目 / 资料")
        #expect(row.ancestorIDs == [parent.id, child.id])
    }

    @Test("过期分类返回全部视图，失去父文件夹的会话仍能从未分类访问")
    func deletedScopeAndOrphanedMembership() {
        let session = ChatSession(id: UUID(), name: "孤立会话", folderID: UUID())
        let all = MacSessionLibrarySnapshot.prepare(sessions: [session], folders: [], tags: [], scope: .folder(UUID()), query: "") { _ in [] }
        #expect(all.scope == .all)
        #expect(all.sessions.map(\.id) == [session.id])
        let unfiled = MacSessionLibrarySnapshot.prepare(sessions: [session], folders: [], tags: [], scope: .unfiled, query: "") { _ in [] }
        #expect(unfiled.unfiledCount == 1)
        #expect(unfiled.sessions.map(\.id) == [session.id])
    }

    @Test("按标签搜索消息正文，系统颜色使用稳定 ID，重复同色只显示一个标记")
    func tagsAndBodySearch() {
        let tag = SessionTag(name: "文档", color: .blue)
        let blueID = SessionTag.systemColorTagID(for: .blue)
        let match = ChatSession(id: UUID(), name: "无关键字标题", tagIDs: [tag.id, blueID])
        let outside = ChatSession(id: UUID(), name: "针叶林", tagIDs: [])
        let snapshot = MacSessionLibrarySnapshot.prepare(sessions: [match, outside], folders: [], tags: [tag], scope: .tag(tag.id), query: "针叶林") { id in
            #expect(id == match.id)
            return [ChatMessage(role: .assistant, content: "研究针叶林的讨论")]
        }
        #expect(snapshot.sessions.map(\.id) == [match.id])
        #expect(snapshot.sessions.first?.subtitle.contains("针叶林") == true)
        #expect(snapshot.sessions.first?.colors == [.blue])
        #expect(snapshot.colorTags.first(where: { $0.id == blueID })?.count == 1)
        #expect(snapshot.tags.map(\.id) == [tag.id])
    }

    @Test("损坏的循环父链能有限展开并保留阻止移动所需的祖先集合")
    func cyclicParentsDoNotLoop() {
        let firstID = UUID()
        let secondID = UUID()
        let folders = [SessionFolder(id: firstID, name: "甲", parentID: secondID), SessionFolder(id: secondID, name: "乙", parentID: firstID)]
        let snapshot = MacSessionLibrarySnapshot.prepare(sessions: [], folders: folders, tags: [], scope: .all, query: "") { _ in [] }
        #expect(snapshot.folders.count == 2)
        #expect(snapshot.folders.allSatisfy { $0.ancestorIDs == [firstID, secondID] })
    }
}
