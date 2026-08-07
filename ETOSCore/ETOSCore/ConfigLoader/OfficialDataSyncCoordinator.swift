// ============================================================================
// OfficialDataSyncCoordinator.swift
// ============================================================================
// 获取官方清单并将“预览”和“确认后执行”分开，避免手动同步在确认前写入数据。
// ============================================================================

import Foundation

enum OfficialDataSyncError: LocalizedError {
    case invalidManifestURL
    case invalidResponse
    case unsupportedManifest
    case invalidDownload(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifestURL:
            return NSLocalizedString("官方数据清单地址无效。", comment: "Official manifest URL invalid")
        case .invalidResponse:
            return NSLocalizedString("官方数据服务返回了无效响应。", comment: "Official data invalid response")
        case .unsupportedManifest:
            return NSLocalizedString("当前版本无法读取这份官方数据清单。", comment: "Official manifest unsupported")
        case .invalidDownload(let name):
            return String(
                format: NSLocalizedString("官方文件“%@”的信息无效。", comment: "Official file metadata invalid"),
                name
            )
        }
    }
}

extension ConfigLoader {
    /// 获取文件和数据库操作预览；此过程不会修改本地文件或数据库。
    public static func prepareOfficialDataSync(
        trigger: OfficialDataSyncTrigger = .manualSync
    ) async throws -> OfficialDataSyncPreview {
        guard let manifestURL = URL(string: officialDataManifestURLString) else {
            throw OfficialDataSyncError.invalidManifestURL
        }

        logger.info("正在获取官方数据清单以生成同步预览...")
        let manifestData = try await fetchOfficialData(from: manifestURL)
        let manifest = try await Task.detached(priority: .utility) {
            try JSONDecoder().decode(OfficialDataManifest.self, from: manifestData)
        }.value
        guard manifest.version == 1 else {
            throw OfficialDataSyncError.unsupportedManifest
        }

        let filePreviews = try manifest.downloads.map { entry in
            guard isValidOfficialDataEntry(entry),
                  resolveDownloadDestination(for: entry.path) != nil,
                  officialDataURL(entry.url, relativeTo: manifestURL) != nil else {
                throw OfficialDataSyncError.invalidDownload(entry.name ?? entry.fileName)
            }
            return OfficialDataPreviewFile(
                id: "\(entry.sha256.lowercased()):\(entry.fileName)",
                name: entry.name ?? entry.fileName,
                fileName: entry.fileName,
                destinationPath: entry.path + "/" + entry.fileName,
                size: entry.size
            )
        }

        var preparedActions: [PreparedOfficialDataAction] = []
        var unavailableOperations: [OfficialDataPreviewOperation] = []
        var preparationFailures: [String] = []

        for entry in manifest.actions where actionEntryApplies(entry, trigger: trigger) {
            do {
                guard isValidOfficialActionEntry(entry),
                      let remoteURL = officialDataURL(entry.url, relativeTo: manifestURL) else {
                    throw OfficialDataSyncError.unsupportedManifest
                }
                let payload = try await fetchOfficialData(from: remoteURL)
                guard officialDataMatches(
                    payload,
                    expectedSize: entry.size,
                    expectedSHA256: entry.sha256
                ) else {
                    throw OfficialDataSyncError.invalidDownload(entry.fileName)
                }
                let bundle = try await Task.detached(priority: .utility) {
                    try JSONDecoder().decode(OfficialDataActionBundle.self, from: payload)
                }.value
                guard isValidOfficialActionBundle(bundle, for: entry) else {
                    throw OfficialDataSyncError.unsupportedManifest
                }
                preparedActions.append(
                    PreparedOfficialDataAction(entry: entry, payload: payload, bundle: bundle)
                )
            } catch {
                let message = error.localizedDescription
                preparationFailures.append(message)
                unavailableOperations.append(
                    OfficialDataPreviewOperation(
                        id: entry.id,
                        providerName: entry.id,
                        providerBaseURL: "",
                        kind: .unavailable,
                        modelNamesToAdd: [],
                        modelNamesToUpdate: [],
                        modelNamesToRemove: [],
                        changesProviderConfiguration: false,
                        preservesLocalCredentials: true,
                        preservesLocalProxy: true,
                        preservesLocalModelActivation: true,
                        detail: message
                    )
                )
            }
        }

        let actionPreviews: [OfficialDataPreviewOperation]
        do {
            actionPreviews = try await Task.detached(priority: .utility) {
                try OfficialProviderActionApplier.preview(
                    preparedActions: preparedActions,
                    trigger: trigger
                )
            }.value
        } catch {
            let message = error.localizedDescription
            preparationFailures.append(message)
            actionPreviews = preparedActions.map { prepared in
                OfficialDataPreviewOperation(
                    id: prepared.entry.id,
                    providerName: prepared.bundle.provider.name,
                    providerBaseURL: prepared.bundle.provider.baseURL,
                    kind: .unavailable,
                    modelNamesToAdd: [],
                    modelNamesToUpdate: [],
                    modelNamesToRemove: [],
                    changesProviderConfiguration: false,
                    preservesLocalCredentials: true,
                    preservesLocalProxy: true,
                    preservesLocalModelActivation: true,
                    detail: message
                )
            }
            preparedActions.removeAll()
        }

        return OfficialDataSyncPreview(
            manifestURL: manifestURL,
            manifest: manifest,
            files: filePreviews,
            operations: actionPreviews + unavailableOperations,
            preparedActions: preparedActions,
            preparationFailures: preparationFailures
        )
    }

    /// 应用用户已经确认的预览；数据库操作在一个配置数据库事务中完成。
    public static func applyOfficialDataSync(
        _ preview: OfficialDataSyncPreview,
        overwriteExisting: Bool = true,
        trigger: OfficialDataSyncTrigger = .manualSync
    ) async -> OfficialDataSyncResult {
        guard beginDownloadOnce() else {
            return OfficialDataSyncResult(
                downloadedCount: 0,
                totalCount: preview.manifest.downloads.count,
                isComplete: false,
                isAlreadyRunning: true
            )
        }
        defer { endDownloadOnce() }

        var downloadedCount = 0
        var failures = preview.preparationFailures
        for entry in preview.manifest.downloads {
            guard let remoteURL = officialDataURL(entry.url, relativeTo: preview.manifestURL),
                  let destinationDir = resolveDownloadDestination(for: entry.path) else {
                failures.append(
                    String(
                        format: NSLocalizedString("无法处理官方文件“%@”。", comment: "Official file unavailable"),
                        entry.name ?? entry.fileName
                    )
                )
                continue
            }
            switch await downloadOfficialDataFile(
                entry,
                from: remoteURL,
                to: destinationDir,
                overwriteExisting: overwriteExisting
            ) {
            case .downloaded:
                downloadedCount += 1
            case .alreadyPresent:
                break
            case .failed:
                failures.append(
                    String(
                        format: NSLocalizedString("下载官方文件“%@”失败。", comment: "Official file download failed"),
                        entry.name ?? entry.fileName
                    )
                )
            }
        }

        var actionSummary = OfficialDataActionSummary.empty
        if !preview.preparedActions.isEmpty {
            do {
                actionSummary = try await Task.detached(priority: .utility) {
                    try OfficialProviderActionApplier.apply(
                        preparedActions: preview.preparedActions,
                        trigger: trigger
                    )
                }.value
            } catch {
                failures.append(error.localizedDescription)
                actionSummary = OfficialDataActionSummary(failedCount: preview.preparedActions.count)
            }
        }

        let result = OfficialDataSyncResult(
            downloadedCount: downloadedCount,
            totalCount: preview.manifest.downloads.count,
            isComplete: failures.isEmpty && preview.unavailableOperationCount == 0,
            isAlreadyRunning: false,
            actionSummary: actionSummary,
            failureMessages: failures
        )
        if result.isComplete {
            setDownloadOnceCompleted(true)
        }
        if result.didChangeData {
            await MainActor.run {
                if result.actionSummary.changedCount > 0 {
                    NotificationCenter.default.post(name: .providerConfigurationDidChange, object: nil)
                }
                NotificationCenter.default.post(name: .officialDataDidUpdate, object: nil)
            }
        }
        return result
    }

    private static func fetchOfficialData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = officialDataTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await NetworkSessionConfiguration.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw OfficialDataSyncError.invalidResponse
        }
        return data
    }

    private static func officialDataURL(_ rawValue: String, relativeTo manifestURL: URL) -> URL? {
        guard let url = URL(string: rawValue, relativeTo: manifestURL)?.absoluteURL,
              url.scheme == manifestURL.scheme,
              url.host == manifestURL.host,
              url.port == manifestURL.port else {
            return nil
        }
        return url
    }

    private static func isValidOfficialDataEntry(_ entry: OfficialDataEntry) -> Bool {
        isValidOfficialFileMetadata(fileName: entry.fileName, sha256: entry.sha256, size: entry.size)
    }

    private static func isValidOfficialActionEntry(_ entry: OfficialDataActionEntry) -> Bool {
        !entry.id.isEmpty &&
            entry.revision > 0 &&
            entry.kind == OfficialDataActionKind.providerUpsert.rawValue &&
            !entry.applyOn.isEmpty &&
            isValidOfficialFileMetadata(fileName: entry.fileName, sha256: entry.sha256, size: entry.size)
    }

    private static func isValidOfficialFileMetadata(fileName: String, sha256: String, size: Int64) -> Bool {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty &&
            trimmed == fileName &&
            !trimmed.contains("/") &&
            !trimmed.contains("\\") &&
            trimmed != "." &&
            trimmed != ".." &&
            size > 0 &&
            sha256.count == 64 &&
            sha256.allSatisfy(\.isHexDigit)
    }

    static func actionEntryApplies(
        _ entry: OfficialDataActionEntry,
        trigger: OfficialDataSyncTrigger
    ) -> Bool {
        let expectedApplyOn: OfficialDataActionApplyOn = trigger == .initialSync ? .initialSync : .manualSync
        return entry.kind == OfficialDataActionKind.providerUpsert.rawValue &&
            entry.revision > 0 &&
            entry.applyOn.contains(expectedApplyOn) &&
            (entry.minimumAppBuild.map { currentAppBuild >= $0 } ?? true) &&
            (entry.platforms.isEmpty || entry.platforms.contains(currentPlatform))
    }

    private static func isValidOfficialActionBundle(
        _ bundle: OfficialDataActionBundle,
        for entry: OfficialDataActionEntry
    ) -> Bool {
        guard bundle.schemaVersion == 1,
              bundle.id == entry.id,
              bundle.revision == entry.revision,
              bundle.kind.rawValue == entry.kind,
              bundle.applyOn == entry.applyOn,
              bundle.minimumAppBuild == entry.minimumAppBuild,
              bundle.platforms == entry.platforms,
              bundle.mergePolicy == entry.mergePolicy,
              bundle.revision > 0,
              !bundle.provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              URL(string: bundle.provider.baseURL)?.scheme == "https",
              Set(bundle.provider.models.map(\.id)).count == bundle.provider.models.count else {
            return false
        }
        return !bundle.applyOn.isEmpty
    }

    private static var currentAppBuild: Int {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return Int(rawValue ?? "") ?? 0
    }

    private static var currentPlatform: OfficialDataActionPlatform {
#if os(watchOS)
        return .watchOS
#else
        return .iOS
#endif
    }
}
