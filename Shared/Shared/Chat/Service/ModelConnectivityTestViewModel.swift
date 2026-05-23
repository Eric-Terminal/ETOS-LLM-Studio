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
    public static let maximumConcurrencyLimit = 16

    @Published public private(set) var results: [ModelConnectivityTestResult]
    @Published public private(set) var isRunning = false
    @Published public private(set) var completedCount = 0
    @Published public var concurrencyLimit: Int

    private let service: ChatService
    private let candidates: [RunnableModel]
    private var testTask: Task<Void, Never>?

    public init(provider: Provider, service: ChatService = .shared, concurrencyLimit: Int = 1) {
        self.service = service
        self.candidates = service.connectivityTestCandidates(for: provider)
        self.results = candidates.map { ModelConnectivityTestResult(runnableModel: $0) }
        self.concurrencyLimit = Self.clampedConcurrencyLimit(concurrencyLimit)
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

    public static func clampedConcurrencyLimit(_ value: Int) -> Int {
        min(max(value, minimumConcurrencyLimit), maximumConcurrencyLimit)
    }

    public func start() {
        guard !isRunning, !candidates.isEmpty else { return }
        let concurrencyLimit = Self.clampedConcurrencyLimit(self.concurrencyLimit)
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

        let maxActiveCount = min(Self.clampedConcurrencyLimit(concurrencyLimit), candidates.count)
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
