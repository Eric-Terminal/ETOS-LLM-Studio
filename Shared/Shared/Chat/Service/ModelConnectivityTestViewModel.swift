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
    @Published public private(set) var results: [ModelConnectivityTestResult]
    @Published public private(set) var isRunning = false
    @Published public private(set) var completedCount = 0

    private let service: ChatService
    private let candidates: [RunnableModel]
    private var testTask: Task<Void, Never>?

    public init(provider: Provider, service: ChatService = .shared) {
        self.service = service
        self.candidates = service.connectivityTestCandidates(for: provider)
        self.results = candidates.map { ModelConnectivityTestResult(runnableModel: $0) }
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

    public func start() {
        guard !isRunning, !candidates.isEmpty else { return }
        testTask?.cancel()
        results = candidates.map { ModelConnectivityTestResult(runnableModel: $0) }
        completedCount = 0
        isRunning = true

        testTask = Task { [weak self] in
            guard let self else { return }
            for candidate in candidates {
                if Task.isCancelled { break }
                updateResult(candidateID: candidate.id) { result in
                    result.status = .testing
                    result.latencyMilliseconds = nil
                    result.responsePreview = nil
                    result.errorMessage = nil
                }
                let testResult = await service.testModelConnectivity(for: candidate)
                updateResult(candidateID: candidate.id) { result in
                    result = testResult
                }
                completedCount += 1
            }
            isRunning = false
        }
    }

    public func cancel() {
        testTask?.cancel()
        testTask = nil
        isRunning = false
    }

    private func updateResult(
        candidateID: String,
        mutate: (inout ModelConnectivityTestResult) -> Void
    ) {
        guard let index = results.firstIndex(where: { $0.id == candidateID }) else { return }
        mutate(&results[index])
    }
}
