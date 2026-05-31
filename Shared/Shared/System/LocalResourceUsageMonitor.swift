// ============================================================================
// LocalResourceUsageMonitor.swift
// ============================================================================
// ETOS LLM Studio
//
// 读取当前 App 进程的 CPU、内存和可用平台上的 Metal 分配量。
// ============================================================================

import Combine
import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Metal) && !os(watchOS)
import Metal
#endif

public struct LocalResourceUsageSnapshot: Hashable, Sendable {
    public var cpuPercent: Double?
    public var memoryBytes: UInt64?
    public var gpuAllocatedBytes: UInt64?

    public init(cpuPercent: Double?, memoryBytes: UInt64?, gpuAllocatedBytes: UInt64?) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.gpuAllocatedBytes = gpuAllocatedBytes
    }

    public var displayText: String {
        var parts: [String] = []
        if let cpuPercent {
            parts.append(String(format: NSLocalizedString("CPU %.0f%%", comment: "Local resource CPU usage"), cpuPercent))
        }
        #if !os(watchOS)
        if let gpuAllocatedBytes {
            parts.append(String(format: NSLocalizedString("GPU %@", comment: "Local resource GPU usage"), StorageUtility.formatSize(Int64(gpuAllocatedBytes))))
        }
        #endif
        if let memoryBytes {
            parts.append(String(format: NSLocalizedString("内存 %@", comment: "Local resource memory usage"), StorageUtility.formatSize(Int64(memoryBytes))))
        }
        return parts.isEmpty ? NSLocalizedString("正在读取本机资源", comment: "Local resource loading placeholder") : parts.joined(separator: " · ")
    }
}

public final class LocalResourceUsageMonitor: ObservableObject {
    public static let shared = LocalResourceUsageMonitor()

    @Published public private(set) var snapshot = LocalResourceUsageSnapshot(
        cpuPercent: nil,
        memoryBytes: nil,
        gpuAllocatedBytes: nil
    )

    private var lastCPUTime: Double?
    private var lastSampleDate: Date?
    #if canImport(Metal) && !os(watchOS)
    private let metalDevice = MTLCreateSystemDefaultDevice()
    #endif

    public init() {}

    @MainActor
    public func refresh() {
        snapshot = LocalResourceUsageSnapshot(
            cpuPercent: currentCPUPercent(),
            memoryBytes: currentResidentMemoryBytes(),
            gpuAllocatedBytes: currentGPUAllocatedBytes()
        )
    }

    private func currentCPUPercent() -> Double? {
        guard let cpuTime = currentProcessCPUTime() else { return nil }
        let now = Date()
        defer {
            lastCPUTime = cpuTime
            lastSampleDate = now
        }
        guard let lastCPUTime, let lastSampleDate else { return nil }
        let elapsed = now.timeIntervalSince(lastSampleDate)
        guard elapsed > 0 else { return nil }
        return max(0, (cpuTime - lastCPUTime) / elapsed * 100)
    }

    private func currentProcessCPUTime() -> Double? {
        var info = task_thread_times_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }

    private func currentResidentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }

    private func currentGPUAllocatedBytes() -> UInt64? {
        #if canImport(Metal) && !os(watchOS)
        guard let metalDevice else { return nil }
        return UInt64(metalDevice.currentAllocatedSize)
        #else
        return nil
        #endif
    }
}
