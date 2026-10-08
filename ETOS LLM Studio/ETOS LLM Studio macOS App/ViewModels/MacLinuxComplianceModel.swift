import Combine
import ETOSCore
import Foundation

struct MacLinuxComplianceRow: Identifiable, Sendable {
    let document: LocalLinuxComplianceDocument
    let title: String
    let symbol: String
    var id: String { document.id }

    static func prepare() -> [Self] {
        LocalLinuxComplianceDocument.allCases.map { document in
            let symbol: String
            switch document {
            case .sourceOffer, .sourceAssets: symbol = "chevron.left.forwardslash.chevron.right"
            case .packages, .sbom, .migrations, .compliance: symbol = "list.bullet.rectangle"
            case .notices, .projectLicenses: symbol = "doc.text"
            }
            return Self(document: document, title: document.displayName, symbol: symbol)
        }
    }
}

/// 根页与文档页各自拥有加载状态；内容只来自应用包，不启动 Linux 或请求网络。
@MainActor
final class MacLinuxComplianceModel: ObservableObject {
    @Published private(set) var rows: [MacLinuxComplianceRow] = []
    @Published private(set) var content = ""
    @Published private(set) var resourceURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var lease = UUID()
    @Published private(set) var error: String?
    private var loading: Task<Void, Never>?
    private var isOpen = false
    private let document: LocalLinuxComplianceDocument?
    init(document: LocalLinuxComplianceDocument? = nil) { self.document = document }

    func open() { guard !isOpen else { return }; isOpen = true; reload() }
    func close(clearContent: Bool = true) {
        isOpen = false; lease = UUID(); loading?.cancel(); isLoading = false; error = nil
        if clearContent { rows = []; content = ""; resourceURL = nil }
    }
    func reload() {
        guard isOpen else { return }
        loading?.cancel(); lease = UUID(); isLoading = true; error = nil
        let lease = lease, document = document
        loading = Task { [weak self] in
            let work = Task.detached(priority: .utility) { () -> ([MacLinuxComplianceRow], String, URL?, String?) in
                do {
                    try Task.checkCancellation()
                    if let document {
                        guard let url = document.resourceURL() else { return ([], "", nil, NSLocalizedString("找不到这份随包资源。", comment: "")) }
                        let content = try String(contentsOf: url, encoding: .utf8)
                        try Task.checkCancellation()
                        return ([], content, url, nil)
                    }
                    let rows = MacLinuxComplianceRow.prepare()
                    do {
                        let seed = try LocalLinuxSeedResource.load()
                        let summary = String(format: NSLocalizedString("Alpine %@ · %@ · %llu 个文件\nSeed SHA-256：%@", comment: ""),
                            seed.metadata.alpineVersion, seed.metadata.guestArchitecture, seed.metadata.entryCount, seed.metadata.archiveSHA256)
                        return (rows, summary, nil, nil)
                    } catch { return (rows, "", nil, error.localizedDescription) }
                } catch { return ([], "", nil, error.localizedDescription) }
            }
            let value = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, self.lease == lease, isOpen, !Task.isCancelled else { return }
            rows = value.0; content = value.1; resourceURL = value.2; error = value.3; isLoading = false
        }
    }
}
