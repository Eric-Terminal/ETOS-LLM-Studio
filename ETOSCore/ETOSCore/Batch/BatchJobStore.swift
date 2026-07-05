// ============================================================================
// BatchJobStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责本地持久化 BatchJob 的状态。采用 JSON 文件存储，适合小规模任务。
// ============================================================================

import Foundation
import os.log

public class BatchJobStore {
    public static let shared = BatchJobStore()
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "BatchJobStore")
    
    private var jobs: [String: BatchJob] = [:]
    private let queue = DispatchQueue(label: "com.ETOS.LLM.Studio.BatchJobStore")
    
    private var fileURL: URL {
        let docsDir = Persistence.documentsDirectory
        let batchDir = docsDir.appendingPathComponent("BatchJobs")
        if !FileManager.default.fileExists(atPath: batchDir.path) {
            try? FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
        }
        return batchDir.appendingPathComponent("jobs.json")
    }
    
    private init() {
        load()
    }
    
    public func saveJob(_ job: BatchJob) {
        queue.async {
            self.jobs[job.id] = job
            self.persist()
        }
    }
    
    public func getJob(id: String) -> BatchJob? {
        queue.sync {
            return jobs[id]
        }
    }
    
    public func getAllJobs() -> [BatchJob] {
        queue.sync {
            return Array(jobs.values).sorted(by: { $0.createdAt > $1.createdAt })
        }
    }
    
    public func removeJob(id: String) {
        queue.async {
            self.jobs.removeValue(forKey: id)
            self.persist()
        }
    }
    
    private func load() {
        queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode([String: BatchJob].self, from: data)
                self.jobs = decoded
                logger.info("成功加载了 \(decoded.count) 个 Batch 任务。")
            } catch {
                logger.error("加载 Batch 任务失败: \(error.localizedDescription)")
            }
        }
    }
    
    private func persist() {
        do {
            let data = try JSONEncoder().encode(jobs)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("保存 Batch 任务失败: \(error.localizedDescription)")
        }
    }
}
