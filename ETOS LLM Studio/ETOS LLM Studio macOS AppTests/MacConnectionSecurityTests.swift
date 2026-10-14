import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

@Suite("Mac 连接例外管理")
struct MacConnectionSecurityTests {
    @Test("目录为详情建立标识索引，仅保留来源、类型和日期")
    func presentationContainsOnlyDisplayFields() throws {
        let state = try fixture()
        let value = MacConnectionSecurityPresentation(state: state)
        let row = try #require(value.addresses.first)
        #expect(value.allowsHTTP && !value.allowsCertificates)
        #expect(row.origin == "http://network-trust.test:7654" && row.kind == .http)
        #expect(!row.createdAt.isEmpty && value.addressesByID[row.id]?.id == row.id)
        #expect(value.addressesByID.count == 1)
    }

    @Test("锁定后迟到读取不能重新发布地址，恢复后重新读取")
    @MainActor
    func suspendedReadDoesNotPublish() async throws {
        let state = try fixture(), gate = MacConnectionTestGate()
        let model = MacConnectionSecurityModel(observeChanges: false, read: {
            await gate.pause()
            return MacConnectionSecurityPresentation(state: state)
        })
        model.reload()
        await gate.waitForArrival()
        model.suspend()
        await gate.release()
        await model.waitForPendingOperations()
        #expect(model.presentation == nil && !model.isLoading && !model.canEdit)
        model.resume(); model.reload()
        await model.waitForPendingOperations()
        #expect(model.presentation?.addresses.count == 1 && model.canEdit)
    }

    @Test("原生修改被接受后锁定仍等待写入，连续点击不能重复提交")
    @MainActor
    func acceptedMutationSurvivesSuspension() async throws {
        let store = MacConnectionTestStore(state: try fixture()), gate = MacConnectionTestGate()
        let model = MacConnectionSecurityModel(observeChanges: false,
            read: { await store.read() }, update: { mutation in await gate.pause(); await store.update(mutation) })
        model.reload(); await model.waitForPendingOperations()
        model.setEnabled(false, kind: .http)
        await gate.waitForArrival()
        model.setEnabled(true, kind: .http)
        model.suspend()
        #expect(model.isSaving)
        await gate.release()
        await model.waitForPendingOperations()
        #expect(await store.writeCount == 1)
        #expect(model.presentation == nil && !model.isSaving)
        model.resume(); model.reload(); await model.waitForPendingOperations()
        #expect(model.presentation?.allowsHTTP == false)
    }

    @Test("删除后使用新目录，旧详情不能重复删除或删除其他记录")
    @MainActor
    func removedRecordIsNotReused() async throws {
        let store = MacConnectionTestStore(state: try fixture())
        let model = MacConnectionSecurityModel(observeChanges: false,
            read: { await store.read() }, update: { await store.update($0) })
        model.reload(); await model.waitForPendingOperations()
        let id = try #require(model.presentation?.addresses.first?.id)
        model.remove(id: id); await model.waitForPendingOperations()
        #expect(model.presentation?.addressesByID[id] == nil)
        model.remove(id: id); model.remove(id: UUID())
        await model.waitForPendingOperations()
        #expect(await store.writeCount == 1)
    }

    @Test("保存失败显示错误并保留实际存储状态")
    @MainActor
    func failureDoesNotClaimRevocation() async throws {
        let state = try fixture()
        let model = MacConnectionSecurityModel(observeChanges: false,
            read: { MacConnectionSecurityPresentation(state: state) },
            update: { _ in throw NetworkConnectionSecurityError.persistenceFailed })
        model.reload(); await model.waitForPendingOperations()
        model.setEnabled(false, kind: .http); await model.waitForPendingOperations()
        #expect(model.presentation?.allowsHTTP == true)
        #expect(model.error != nil && model.canEdit)
    }

    @Test("双语知识明确原生信任决定、独立进程边界及恢复后重读")
    func guideKeepsTrustDecisionsNative() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh_CN")).content
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en_US")).content
        #expect(chinese.contains("连接例外") && chinese.contains("原生 stdio 子进程"))
        #expect(english.contains("Connection Exceptions") && english.contains("native stdio child processes"))
    }

    private func fixture() throws -> NetworkConnectionSecurityState {
        // 用现有 Codable 格式构造记录，不读写应用数据库或钥匙串。
        let data = Data("""
        {"allowsHTTPExceptions":true,"allowsCertificateExceptions":false,"exceptions":[
          {"id":"31C30C6F-008E-459A-976E-AB830C01B603","origin":{"scheme":"http","host":"network-trust.test","port":7654},
           "kind":"http","createdAt":800000000,"trustExceptions":"cHJpdmF0ZS10cnVzdC1ieXRlcw=="}
        ]}
        """.utf8)
        return try JSONDecoder().decode(NetworkConnectionSecurityState.self, from: data)
    }
}

private actor MacConnectionTestStore {
    var state: NetworkConnectionSecurityState
    private(set) var writeCount = 0
    init(state: NetworkConnectionSecurityState) { self.state = state }
    func read() -> MacConnectionSecurityPresentation { MacConnectionSecurityPresentation(state: state) }
    func update(_ mutation: MacConnectionSecurityMutation) {
        writeCount += 1
        switch mutation {
        case .setEnabled(let enabled, .http): state.allowsHTTPExceptions = enabled
        case .setEnabled(let enabled, .certificate): state.allowsCertificateExceptions = enabled
        case .remove(let id): state.exceptions.removeAll { $0.id == id }
        }
    }
}

private actor MacConnectionTestGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }; arrivalWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func waitForArrival() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll()
    }
}
