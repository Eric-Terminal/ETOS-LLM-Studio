// ============================================================================
// PerformanceTelemetryCenter.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS MetricKit 订阅、启动快照上传与用户可见状态的唯一协调入口。
// ============================================================================

#if os(iOS) && canImport(MetricKit)
import Foundation
import Combine
import MetricKit
import os.log

@MainActor
public final class PerformanceTelemetryCenter: NSObject, ObservableObject {
    public static let shared = PerformanceTelemetryCenter()

    @Published public private(set) var isEnabled = false
    @Published public private(set) var pendingRecords: [TelemetryLogRecord] = []
    @Published public private(set) var sentThisLaunchRecords: [TelemetryLogRecord] = []
    @Published public private(set) var pendingBytes: Int64 = 0
    @Published public private(set) var isUploading = false
    @Published public private(set) var lastUploadError: String?

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "PerformanceTelemetry")
    private let store: TelemetryStore
    private let uploader: any TelemetryUploading
    private let appMetadata: TelemetryAppMetadata
    private let platformMetadata: TelemetryPlatformMetadata
    private var isSubscribed = false
    private var uploadTask: Task<Void, Never>?
    private var launchSignpost: TelemetrySignpostToken?

    public override init() {
        self.store = TelemetryStore()
        self.uploader = TelemetryUploader()
        self.appMetadata = .current
        self.platformMetadata = .currentIOS
        super.init()
    }

    init(
        store: TelemetryStore,
        uploader: any TelemetryUploading,
        appMetadata: TelemetryAppMetadata,
        platformMetadata: TelemetryPlatformMetadata
    ) {
        self.store = store
        self.uploader = uploader
        self.appMetadata = appMetadata
        self.platformMetadata = platformMetadata
        super.init()
    }

    public func configure(enabled: Bool) async {
        if enabled {
            await startIfNeeded()
        } else {
            await stopAndClear()
        }
    }

    public func refreshVisibleRecords() async {
        let snapshot = await store.loadCurrentSnapshot()
        applyPendingSnapshot(snapshot)
    }

    public func clearPendingData() async {
        await store.clearPending()
        await refreshVisibleRecords()
    }

    public func prepareLaunchMeasurement(enabled: Bool) {
        guard enabled else { return }
        TelemetrySignpost.setEnabled(true)
        if launchSignpost == nil {
            launchSignpost = TelemetrySignpost.begin(.appLaunch)
        }
    }

    public func markFirstInterfaceReady() {
        guard let launchSignpost else { return }
        TelemetrySignpost.end(launchSignpost)
        self.launchSignpost = nil
    }

    private func startIfNeeded() async {
        guard !isSubscribed else {
            isEnabled = true
            return
        }

        isEnabled = true
        prepareLaunchMeasurement(enabled: true)

        // 先冻结本次启动可上传的文件，再订阅新的回调，保证新 Payload 留到下次启动。
        let launchSnapshot = await store.prepareLaunchSnapshot()
        applyPendingSnapshot(launchSnapshot)

        MXMetricManager.shared.add(self)
        isSubscribed = true

        uploadTask?.cancel()
        uploadTask = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.uploadLaunchSnapshot(launchSnapshot.files)
        }
    }

    private func stopAndClear() async {
        isEnabled = false
        TelemetrySignpost.setEnabled(false)
        if let launchSignpost {
            TelemetrySignpost.end(launchSignpost)
            self.launchSignpost = nil
        }

        uploadTask?.cancel()
        uploadTask = nil
        if isSubscribed {
            MXMetricManager.shared.remove(self)
            isSubscribed = false
        }

        await store.clearPending()
        pendingRecords = []
        sentThisLaunchRecords = []
        pendingBytes = 0
        lastUploadError = nil
        isUploading = false
    }

    private func uploadLaunchSnapshot(_ files: [TelemetryStoredFile]) async {
        guard isEnabled, !files.isEmpty else { return }
        let uploadableFiles = files.filter {
            $0.fileSizeBytes <= TelemetryStore.defaultMaxUploadFileBytes
        }
        guard !uploadableFiles.isEmpty else { return }

        isUploading = true
        defer { isUploading = false }

        let outcome = await uploader.upload(uploadableFiles)
        guard isEnabled else { return }

        let confirmed = outcome.confirmedPayloadIDs
        if !confirmed.isEmpty {
            await store.deleteConfirmed(payloadIDs: confirmed)
            let sent = uploadableFiles
                .filter { confirmed.contains($0.envelope.payloadID) }
                .map {
                    $0.makeLogRecord(
                        state: .sentThisLaunch,
                        maxUploadFileBytes: TelemetryStore.defaultMaxUploadFileBytes
                    )
                }
            sentThisLaunchRecords = Array((sentThisLaunchRecords + sent).suffix(32))
        }

        lastUploadError = outcome.errorDescription
        await store.recordUploadAttempt(
            error: outcome.errorDescription,
            succeeded: !confirmed.isEmpty
        )
        await refreshVisibleRecords()
    }

    private func receivePayload(
        kind: TelemetryPayloadKind,
        data: Data,
        periodStart: Date?,
        periodEnd: Date?
    ) async {
        guard isEnabled else { return }
        _ = await store.save(
            kind: kind,
            rawPayloadData: data,
            capturedAt: Date(),
            periodStart: periodStart,
            periodEnd: periodEnd,
            app: appMetadata,
            platform: platformMetadata
        )
        await refreshVisibleRecords()
    }

    private func applyPendingSnapshot(_ snapshot: TelemetryStoreSnapshot) {
        pendingBytes = snapshot.totalBytes
        pendingRecords = snapshot.files.map {
            $0.makeLogRecord(
                state: .pending,
                maxUploadFileBytes: TelemetryStore.defaultMaxUploadFileBytes
            )
        }
    }
}

extension PerformanceTelemetryCenter: MXMetricManagerSubscriber {
    public nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            let periodStart = payload.timeStampBegin
            let periodEnd = payload.timeStampEnd
            Task { @MainActor [weak self] in
                await self?.receivePayload(
                    kind: .metric,
                    data: data,
                    periodStart: periodStart,
                    periodEnd: periodEnd
                )
            }
        }
    }

    public nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            let periodStart = payload.timeStampBegin
            let periodEnd = payload.timeStampEnd
            Task { @MainActor [weak self] in
                await self?.receivePayload(
                    kind: .diagnostic,
                    data: data,
                    periodStart: periodStart,
                    periodEnd: periodEnd
                )
            }
        }
    }
}
#endif
