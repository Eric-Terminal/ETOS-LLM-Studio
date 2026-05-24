// ============================================================================
// ModelConnectivityTestViewModel.swift
// ============================================================================
// ETOS LLM Studio
//
// 管理模型连通性批量测试状态。
// ============================================================================

import Combine
import Foundation

@MainActor
public final class ModelConnectivityTestViewModel: ObservableObject {
    public static let minimumConcurrencyLimit = 1

    @Published public private(set) var results: [ModelConnectivityTestResult]
    @Published public private(set) var isRunning = false
    @Published public private(set) var completedCount = 0
    @Published public var concurrencyLimit: Int {
        didSet {
            guard concurrencyLimit != oldValue else { return }
            let normalizedLimit = Self.normalizedConcurrencyLimit(concurrencyLimit)
            if concurrencyLimit != normalizedLimit {
                concurrencyLimit = normalizedLimit
            }
            if appConfig.modelConnectivityTestConcurrencyLimit != normalizedLimit {
                appConfig.modelConnectivityTestConcurrencyLimit = normalizedLimit
            }
        }
    }

    private let service: ChatService
    private let appConfig: AppConfigStore
    private let candidates: [RunnableModel]
    private var testTask: Task<Void, Never>?

    public init(
        provider: Provider,
        service: ChatService = .shared,
        appConfig: AppConfigStore = .shared
    ) {
        self.service = service
        self.appConfig = appConfig
        self.candidates = service.connectivityTestCandidates(for: provider)
        self.results = candidates.map { ModelConnectivityTestResult(runnableModel: $0) }
        self.concurrencyLimit = Self.normalizedConcurrencyLimit(appConfig.modelConnectivityTestConcurrencyLimit)
        if appConfig.modelConnectivityTestConcurrencyLimit != self.concurrencyLimit {
            appConfig.modelConnectivityTestConcurrencyLimit = self.concurrencyLimit
        }
    }

    deinit {
        testTask?.cancel()
    }

    public var totalCount: Int {
        results.count
    }

    public var succeededCount: Int {
        results.filter { $0.status == .succeeded }.count
    }

    public var failedCount: Int {
        results.filter { $0.status == .failed }.count
    }

    public var progressText: String {
        String(format: NSLocalizedString("%d / %d 已完成", comment: "Model test progress"), completedCount, totalCount)
    }

    public static func normalizedConcurrencyLimit(_ value: Int) -> Int {
        max(value, minimumConcurrencyLimit)
    }

    public func start() {
        guard !isRunning, !candidates.isEmpty else { return }
        let concurrencyLimit = Self.normalizedConcurrencyLimit(self.concurrencyLimit)
        self.concurrencyLimit = concurrencyLimit
        testTask?.cancel()
        results = candidates.map { ModelConnectivityTestResult(runnableModel: $0) }
        completedCount = 0
        isRunning = true

        testTask = Task { [weak self] in
            guard let self else { return }
            await runTests(concurrencyLimit: concurrencyLimit)
        }
    }

    public func cancel() {
        testTask?.cancel()
        testTask = nil
        isRunning = false
    }

    private func runTests(concurrencyLimit: Int) async {
        defer {
            isRunning = false
        }

        let maxActiveCount = min(Self.normalizedConcurrencyLimit(concurrencyLimit), candidates.count)
        await withTaskGroup(of: ModelConnectivityTestResult.self) { group in
            var nextCandidateIndex = 0
            var activeTaskCount = 0

            while activeTaskCount < maxActiveCount,
                  nextCandidateIndex < candidates.count,
                  !Task.isCancelled {
                let candidate = candidates[nextCandidateIndex]
                nextCandidateIndex += 1
                markCandidateAsTesting(candidate)
                group.addTask { [service] in
                    await service.testModelConnectivity(for: candidate)
                }
                activeTaskCount += 1
            }

            while activeTaskCount > 0 {
                guard let testResult = await group.next() else { break }
                activeTaskCount -= 1
                updateResult(candidateID: testResult.id) { result in
                    result = testResult
                }
                completedCount += 1

                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }

                if nextCandidateIndex < candidates.count {
                    let candidate = candidates[nextCandidateIndex]
                    nextCandidateIndex += 1
                    markCandidateAsTesting(candidate)
                    group.addTask { [service] in
                        await service.testModelConnectivity(for: candidate)
                    }
                    activeTaskCount += 1
                }
            }
        }
    }

    private func markCandidateAsTesting(_ candidate: RunnableModel) {
        updateResult(candidateID: candidate.id) { result in
            result.status = .testing
            result.latencyMilliseconds = nil
            result.responsePreview = nil
            result.errorMessage = nil
        }
    }

    private func updateResult(
        candidateID: String,
        mutate: (inout ModelConnectivityTestResult) -> Void
    ) {
        guard let index = results.firstIndex(where: { $0.id == candidateID }) else { return }
        mutate(&results[index])
    }
}

@MainActor
public final class SingleModelConnectivityTestViewModel: ObservableObject {
    @Published public private(set) var results: [SingleModelConnectivityTestResult]
    @Published public private(set) var isRunning = false
    @Published public private(set) var completedCount = 0

    public let runnableModel: RunnableModel

    private let service: ChatService
    private var testTask: Task<Void, Never>?

    public init(
        provider: Provider,
        model: Model,
        service: ChatService = .shared
    ) {
        self.runnableModel = RunnableModel(provider: provider, model: model)
        self.service = service
        self.results = Self.makeInitialResults()
    }

    deinit {
        testTask?.cancel()
    }

    public var totalCount: Int {
        results.count
    }

    public var progressText: String {
        String(format: NSLocalizedString("%d / %d 已完成", comment: "Model test progress"), completedCount, totalCount)
    }

    public func start() {
        guard !isRunning else { return }
        testTask?.cancel()
        results = Self.makeInitialResults()
        completedCount = 0
        isRunning = true

        testTask = Task { [weak self] in
            guard let self else { return }
            await runTests()
        }
    }

    public func cancel() {
        testTask?.cancel()
        testTask = nil
        isRunning = false
    }

    private static func makeInitialResults() -> [SingleModelConnectivityTestResult] {
        SingleModelConnectivityTestResult.Kind.allCases.map {
            SingleModelConnectivityTestResult(kind: $0)
        }
    }

    private func runTests() async {
        defer {
            isRunning = false
        }

        await runTest(.nonStreaming)
        guard !Task.isCancelled else { return }
        await runTest(.streaming)
        guard !Task.isCancelled else { return }
        await runTest(.toolCalling)
    }

    private func runTest(_ kind: SingleModelConnectivityTestResult.Kind) async {
        updateResult(kind) { result in
            result.status = .testing
            result.latencyMilliseconds = nil
            result.responsePreview = nil
            result.errorMessage = nil
        }

        let testResult: SingleModelConnectivityTestResult
        switch kind {
        case .nonStreaming:
            testResult = await service.testSingleModelNonStreamingConnectivity(for: runnableModel)
        case .streaming:
            testResult = await service.testSingleModelStreamingConnectivity(for: runnableModel)
        case .toolCalling:
            testResult = await service.testSingleModelToolCallingConnectivity(for: runnableModel)
        }

        updateResult(kind) { result in
            result = testResult
        }
        completedCount += 1
    }

    private func updateResult(
        _ kind: SingleModelConnectivityTestResult.Kind,
        mutate: (inout SingleModelConnectivityTestResult) -> Void
    ) {
        guard let index = results.firstIndex(where: { $0.kind == kind }) else { return }
        mutate(&results[index])
    }
}
