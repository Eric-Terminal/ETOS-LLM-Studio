import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

@MainActor
@Suite("Mac 远程访问生命周期")
struct MacRemoteAccessTests {
    @Test("后台读取保存地址，读取和恢复本身不连接或扫描")
    func loadingDoesNotConnect() async {
        var connections = 0
        let model = MacRemoteAccessModel(readAddress: { #expect(!Thread.isMainThread); return "debug.test:7654" },
            saveAddress: { _ in }, connectServer: { _, _ in connections += 1 })
        model.load(); await model.waitForPendingOperations()
        #expect(model.address == "debug.test:7654" && model.canConnect)
        #expect(connections == 0 && !model.discovery.isSearching)
        model.suspend(); await model.waitForPendingOperations(); model.resume()
        #expect(connections == 0 && !model.connectionRequested)
    }

    @Test("锁定后迟到的地址读取不再更新草稿，恢复后可重新读取")
    func suspendedReadCannotRestoreDraft() async {
        let arrived = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        let model = MacRemoteAccessModel(readAddress: {
            arrived.continuation.yield(()); release.wait()
            return "late.test:7654"
        }, saveAddress: { _ in }, connectServer: { _, _ in Issue.record("读取不应发起连接") })
        model.load()
        var arrivals = arrived.stream.makeAsyncIterator()
        _ = await arrivals.next()
        model.suspend(); release.signal()
        await model.waitForPendingOperations()
        #expect(model.address.isEmpty && model.isSuspended && !model.isLoading)
        model.resume(); release.signal(); model.load()
        await model.waitForPendingOperations()
        #expect(model.address == "late.test:7654")
        arrived.continuation.finish()
    }

    @Test("保存地址期间断开会等待保存结束，迟到完成不能发起连接")
    func disconnectWaitsForAcceptedAddressWrite() async {
        let arrived = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        var connections = 0
        let model = MacRemoteAccessModel(readAddress: { "" }, saveAddress: { value in
            #expect(!Thread.isMainThread && value == "debug.test:7654")
            arrived.continuation.yield(()); arrived.continuation.finish(); release.wait()
        }, connectServer: { _, _ in connections += 1 })
        model.address = "  debug.test:7654\n"; model.connect()
        var arrivals = arrived.stream.makeAsyncIterator()
        _ = await arrivals.next()
        model.disconnect()
        #expect(model.isStopping && !model.canConnect)
        release.signal(); await model.waitForPendingOperations()
        #expect(connections == 0 && !model.connectionRequested && model.canEdit)
    }

    @Test("连接重复点击只接受一次；模式编辑改变代次且连接期间不能修改")
    func repeatedConnectAndDraftEditing() async {
        var connections: [String] = []
        let model = MacRemoteAccessModel(readAddress: { "" }, saveAddress: { _ in }, connectServer: { server, address in
            connections.append(address); server.isRunning = true
        })
        model.address = "debug.test:7654"
        let before = model.epoch
        model.setHTTP(false)
        #expect(model.epoch != before && !model.useHTTP)
        model.connect(); model.connect(); await model.waitForPendingOperations()
        #expect(connections == ["debug.test:7654"] && model.server.isRunning && !model.canEdit)
        model.setHTTP(true)
        #expect(!model.useHTTP)
        model.disconnect(); await model.waitForPendingOperations()
        #expect(!model.server.isRunning && model.canEdit)
    }

    @Test("地址保存失败不发起网络连接，并恢复可编辑状态")
    func failedAddressWriteDoesNotConnect() async {
        let model = MacRemoteAccessModel(readAddress: { "" }, saveAddress: { _ in throw MacMemoryWriteError.busy },
            connectServer: { _, _ in Issue.record("保存失败后不应连接") })
        model.address = "debug.test:7654"; model.connect(); await model.waitForPendingOperations()
        #expect(model.error != nil && model.canEdit && !model.connectionRequested)
    }

    @Test("远程命令自身进入维护时只暂停界面，恢复后保留原连接意图")
    func remoteMaintenanceKeepsCurrentCommandConnection() async {
        var connections = 0
        let model = MacRemoteAccessModel(readAddress: { "" }, saveAddress: { _ in }, connectServer: { server, _ in
            connections += 1; server.isRunning = true
        })
        model.address = "debug.test:7654"; model.connect(); await model.waitForPendingOperations()
        model.suspend(disconnectConnection: false)
        #expect(model.server.isRunning && model.connectionRequested && model.isSuspended)
        model.resume()
        #expect(model.server.isRunning && model.connectionRequested && connections == 1)
        model.suspend(); await model.waitForPendingOperations()
        #expect(!model.server.isRunning && !model.connectionRequested)
    }

    @Test("日志预处理保留顺序和日期；暂停清除展示，迟到日志不能重新显示")
    func logPresentationStaysOutOfSuspendedUI() async throws {
        let model = MacRemoteAccessModel(readAddress: { "" }, saveAddress: { _ in }, connectServer: { _, _ in })
        model.server.addLog("第一条"); model.server.addLog("第二条", type: .error)
        model.refreshPresentation(); await model.waitForPendingOperations()
        let rows = try #require(model.presentation?.logs)
        #expect(rows.map(\.message) == ["第二条", "第一条"] && rows[0].isError && !rows[0].time.isEmpty)
        model.suspend(); model.server.addLog("迟到内容")
        await model.waitForPendingOperations()
        #expect(model.presentation == nil)
    }

    @Test("向导知识区分草稿和连接，限制日志内容及捕获执行权限")
    func guideDocumentsNativeBoundaries() {
        let chinese = GuideRemoteAccessKnowledge.document(locale: Locale(identifier: "zh_CN")).content
        let english = GuideRemoteAccessKnowledge.document(locale: Locale(identifier: "en_US")).content
        #expect(chinese.contains("地址为不可读") && chinese.contains("提案不会保存地址"))
        #expect(english.contains("write-only") && english.contains("cannot scan, connect, disconnect"))
        #expect(GuideDocumentCatalog.documents.contains { $0.id == "remote-file-access" })
    }
}
