// ============================================================================
// LocalLinuxComplianceView.swift
// ============================================================================
// ETOS LLM Studio
// ============================================================================

import ETOSCore
import SwiftUI

struct LocalLinuxComplianceView: View {
    @State private var seedSummary = NSLocalizedString("正在读取内置系统清单…", comment: "Loading Linux compliance summary")

    var body: some View {
        List {
            Section(NSLocalizedString("内置系统", comment: "Bundled Linux system section")) {
                Text(seedSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                ForEach(LocalLinuxComplianceDocument.allCases) { document in
                    NavigationLink {
                        LocalLinuxComplianceDocumentView(document: document)
                    } label: {
                        Label(document.displayName, systemImage: icon(for: document))
                    }
                }
            } header: {
                Text(NSLocalizedString("许可与源码", comment: "Linux licenses and source section"))
            } footer: {
                Text(NSLocalizedString("这些文件与当前 App 内置的 RootFS 一起签名交付，可用于核对版本、许可证、来源与构建材料。", comment: "Linux compliance documents footer"))
            }
        }
        .navigationTitle(NSLocalizedString("许可与源码", comment: "Linux compliance title"))
        .task { await loadSeedSummary() }
    }

    private func icon(for document: LocalLinuxComplianceDocument) -> String {
        switch document {
        case .sourceOffer, .sourceAssets: return "chevron.left.forwardslash.chevron.right"
        case .packages, .sbom, .migrations, .compliance: return "list.bullet.rectangle"
        case .notices, .projectLicenses: return "doc.text"
        }
    }

    private func loadSeedSummary() async {
        seedSummary = await Task.detached(priority: .utility) {
            do {
                let seed = try LocalLinuxSeedResource.load()
                return String(
                    format: NSLocalizedString("Alpine %@ · %@ · %llu 个文件\nSeed SHA-256：%@", comment: "Bundled Linux seed summary"),
                    seed.metadata.alpineVersion,
                    seed.metadata.guestArchitecture,
                    seed.metadata.entryCount,
                    seed.metadata.archiveSHA256
                )
            } catch {
                return error.localizedDescription
            }
        }.value
    }
}

private struct LocalLinuxComplianceDocumentView: View {
    let document: LocalLinuxComplianceDocument
    @State private var content = NSLocalizedString("正在读取…", comment: "Loading Linux compliance document")
    @State private var resourceURL: URL?

    var body: some View {
        ScrollView {
            Text(content)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(document.displayName)
        .toolbar {
            if let resourceURL {
                ShareLink(item: resourceURL) {
                    Label(NSLocalizedString("导出", comment: "Export Linux compliance document"), systemImage: "square.and.arrow.up")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let result: (String, URL?) = await Task.detached(priority: .utility) {
            guard let url = document.resourceURL() else {
                return (NSLocalizedString("找不到这份随包资源。", comment: "Missing Linux compliance document"), nil)
            }
            do {
                return (try String(contentsOf: url, encoding: .utf8), url)
            } catch {
                return (error.localizedDescription, url)
            }
        }.value
        content = result.0
        resourceURL = result.1
    }
}
