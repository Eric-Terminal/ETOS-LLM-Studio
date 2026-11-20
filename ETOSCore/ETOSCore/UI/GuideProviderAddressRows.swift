import SwiftUI

public enum GuideProviderAddressDisclosure {
    /// 粘贴中的字符串可能只是一个密钥。地址通过诊断后才允许进入页面快照或撤销记录。
    public static func readable(_ address: String) -> String? {
        if address.isEmpty { return "" }
        return GuideURLDiagnostics.diagnose(address).normalizedBaseURL == nil ? nil : address
    }

    public static func field(_ address: String, access: GuideSnapshotAccess) -> GuideSnapshotField {
        let visible = readable(address)
        return GuideSnapshotField(label: NSLocalizedString("API 地址", value: "API Address", comment: "提供商地址快照字段"),
            value: .string(visible ?? GuideSnapshotField.hiddenValue), access: visible == nil && access == .readWrite ? .writeOnly : access)
    }
}

public struct GuideProviderAddressRows: View {
    @Binding private var baseURL: String
    private let report: GuideURLDiagnostics?

    public init(baseURL: Binding<String>, report: GuideURLDiagnostics?) {
        _baseURL = baseURL
        self.report = report
    }

    public var body: some View {
        Group {
            if let report, let explanation = report.explanation() {
                if let normalized = report.normalizedBaseURL, normalized != baseURL,
                   report.issue == .trimmed || report.issue == .endpointRemoved {
                    Label {
                        VStack(alignment: .leading) {
                            Text(explanation)
                            Text(verbatim: normalized)
                        }
                    } icon: {
                        Image(systemName: "wand.and.stars").foregroundStyle(.orange)
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    Button(NSLocalizedString("一键修正地址", value: "Use Suggested Address", comment: "采用建议的基础地址")) {
                        baseURL = normalized
                    }
                    .buttonStyle(.borderless)
                } else if report.issue == .missingScheme || report.issue == .embeddedCredentials || report.issue == .invalidAddress {
                    Label { Text(explanation) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}
