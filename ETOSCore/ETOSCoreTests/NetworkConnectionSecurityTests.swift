import Foundation
import Security
import Testing

@testable import ETOSCore

@Suite("连接例外策略")
struct NetworkConnectionSecurityTests {
    @Test("授权来源忽略路径和凭据，区分协议及端口")
    func originMatching() throws {
        let first = try #require(
            NetworkConnectionOrigin(url: URL(string: "http://user:secret@EXAMPLE.com:80/v1?key=secret")!))
        let same = try #require(NetworkConnectionOrigin(url: URL(string: "http://example.com/other")!))
        #expect(first == same)
        #expect(first.displayName == "http://example.com:80")
        #expect(first != NetworkConnectionOrigin(url: URL(string: "https://example.com")!))
        #expect(first != NetworkConnectionOrigin(url: URL(string: "http://example.com:11434")!))
        #expect(NetworkConnectionOrigin(url: URL(string: "file:///tmp/example")!) == nil)
    }

    @Test("自有域名保护使用完整域名边界")
    func appServiceBoundary() {
        for host in ["els.ericterminal.com", "feedback.els.ericterminal.com", "ELS.ERICTERMINAL.COM."] {
            #expect(NetworkConnectionOrigin(url: URL(string: "http://\(host)")!)?.isAppService == true)
        }
        for host in ["notels.ericterminal.com", "els.ericterminal.com.example.org"] {
            #expect(NetworkConnectionOrigin(url: URL(string: "http://\(host)")!)?.isAppService == false)
        }
    }

    @Test("默认拒绝 HTTP，正常 HTTPS 不询问")
    func defaultPolicy() async throws {
        let security = NetworkConnectionSecurity(persistent: false, ask: { _, _, _, _ in .cancel })
        try await security.authorizeHTTP(URL(string: "https://example.com"))
        await #expect(throws: NetworkConnectionSecurityError.denied) {
            try await security.authorizeHTTP(URL(string: "http://example.com"))
        }
        let state = await security.snapshot()
        #expect(!state.allowsHTTPExceptions)
        #expect(!state.allowsCertificateExceptions)
        #expect(state.exceptions.isEmpty)
    }

    @Test("仅本次授权不保存记录或开启总开关")
    func oneTimeApproval() async throws {
        let security = NetworkConnectionSecurity(persistent: false, ask: { _, _, _, _ in .once })
        try await security.authorizeHTTP(URL(string: "http://example.com:11434/v1"))
        let state = await security.snapshot()
        #expect(state.exceptions.isEmpty)
        #expect(!state.allowsHTTPExceptions)
    }

    @Test("记住的地址跨路径生效，更换端口仍被阻止")
    func rememberedOrigin() async throws {
        let security = NetworkConnectionSecurity(persistent: false, ask: { _, _, _, _ in .cancel })
        let origin = try #require(NetworkConnectionOrigin(url: URL(string: "http://example.com:11434/v1")!))
        try await security.remember(origin: origin, kind: .http, trustExceptions: nil)
        try await security.authorizeHTTP(URL(string: "http://example.com:11434/models"))
        await #expect(throws: NetworkConnectionSecurityError.denied) {
            try await security.authorizeHTTP(URL(string: "http://example.com:8080/models"))
        }
    }

    @Test("关闭总开关和移除记录都会撤销可复用的授权")
    func revocation() async throws {
        let security = NetworkConnectionSecurity(persistent: false, ask: { _, _, _, _ in .cancel })
        let url = URL(string: "http://example.com:11434")!
        let origin = try #require(NetworkConnectionOrigin(url: url))
        try await security.remember(origin: origin, kind: .http, trustExceptions: nil)
        try await security.setEnabled(false, for: .http)
        await #expect(throws: NetworkConnectionSecurityError.denied) { try await security.authorizeHTTP(url) }
        try await security.setEnabled(true, for: .http)
        try await security.authorizeHTTP(url)
        let state = await security.snapshot()
        let record = try #require(state.exceptions.first)
        try await security.removeException(id: record.id)
        await #expect(throws: NetworkConnectionSecurityError.denied) { try await security.authorizeHTTP(url) }
    }

    @Test("显式同意也不能为自有服务创建 HTTP 例外")
    func appServiceCannotBeExempted() async throws {
        let security = NetworkConnectionSecurity(persistent: false, ask: { _, _, _, _ in .remember })
        await #expect(throws: NetworkConnectionSecurityError.denied) {
            try await security.authorizeHTTP(URL(string: "http://feedback.els.ericterminal.com"))
        }
        let state = await security.snapshot()
        #expect(state.exceptions.isEmpty)
    }

    @Test("导入伪造记录或其他安装的记录不会取得信任")
    func authenticatedPersistence() throws {
        var state = NetworkConnectionSecurityState()
        state.allowsHTTPExceptions = true
        state.authenticationCode = NetworkConnectionSecurity.authenticationCode(for: state, secret: "device-a")
        #expect(NetworkConnectionSecurity.isAuthentic(state, secret: "device-a"))
        #expect(!NetworkConnectionSecurity.isAuthentic(state, secret: "device-b"))
        state.allowsCertificateExceptions = true
        #expect(!NetworkConnectionSecurity.isAuthentic(state, secret: "device-a"))
    }

    @Test("证书例外只接受原证书，换证书或新增过期错误仍拒绝")
    func certificateReevaluation() async throws {
        let security = NetworkConnectionSecurity(persistent: false, ask: { _, _, _, _ in .cancel })
        let origin = try #require(NetworkConnectionOrigin(url: URL(string: "https://network-trust.test")!))
        let first = try makeTrust(certificate: Self.firstCertificate)
        #expect(!SecTrustEvaluateWithError(first, nil))
        let cookie = try #require(SecTrustCopyExceptions(first))
        try await security.remember(origin: origin, kind: .certificate, trustExceptions: cookie as Data)
        let same = try makeTrust(certificate: Self.firstCertificate)
        #expect(await security.accepts(same, origin: origin))
        let changed = try makeTrust(certificate: Self.secondCertificate)
        #expect(await security.accepts(changed, origin: origin) == false)
        let expired = try makeTrust(
            certificate: Self.firstCertificate, verificationDate: Date(timeIntervalSince1970: 2_200_000_000))
        #expect(await security.accepts(expired, origin: origin) == false)
    }

    @Test("向导文档包含权限边界且不提供信任决策工具")
    func guideDocumentation() throws {
        let document = try #require(GuideDocumentCatalog.documents.first { $0.id == "network-connection-exceptions" })
        #expect(document.content.contains("不能批准连接"))
        #expect(document.content.contains("本地 Linux"))
    }

    private func makeTrust(
        certificate base64: String, verificationDate: Date = Date(timeIntervalSince1970: 1_900_000_000)
    ) throws -> SecTrust {
        let data = try #require(Data(base64Encoded: base64))
        let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        #expect(
            SecTrustCreateWithCertificates(
                certificate, SecPolicyCreateSSL(true, "network-trust.test" as CFString), &trust) == errSecSuccess)
        let resolved = try #require(trust)
        SecTrustSetNetworkFetchAllowed(resolved, false)
        SecTrustSetVerifyDate(resolved, verificationDate as CFDate)
        return resolved
    }

    // 仅包含公开的自签名测试证书，私钥不进入仓库；固定验证时间避免随时钟变化。
    private static let firstCertificate =
        "MIIDGzCCAgOgAwIBAgIUU2sGm9zI59e8x8WlfhX5YD9a9TowDQYJKoZIhvcNAQELBQAwHTEbMBkGA1UEAwwSbmV0d29yay10cnVzdC50ZXN0MB4XDTI2MDkxMzA2MTQxN1oXDTM2MDkxMDA2MTQxN1owHTEbMBkGA1UEAwwSbmV0d29yay10cnVzdC50ZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlClJM+VF3wWMIoL3u/Ri/E9ot8Z0/CkY5gGwYrgY57xhGSOb3CGyrgDbUKrFETLeKnP5j6P7zgATm0zZNr+CAfizWlCS4XJt6+M0FqVtH7LsI0hToMpswMLsF+NsEqcJe/8w3Cxxhj1QotLUsztCqy76BanHDuOMAj37JPHgJoPM5Y+0RLM45NPq6eE+86y3WE+W9yHwRjBLvuKCUA8yXypLfzJU1PzW3JHLyQZh1CO/tP9uJ3sE4o9cF455Tpl0Mc4OpYgnyZb5f1nGl8F/XcDhWPPlkwtNHFBG8wgaZrUYF6uP7gXzJ+qymAI9GFeZwqskJ0MA1exe1YYMzKVbKwIDAQABo1MwUTAdBgNVHQ4EFgQUynCtMRqShrdRUqRs+mcXQoEmOQQwHwYDVR0jBBgwFoAUynCtMRqShrdRUqRs+mcXQoEmOQQwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAGgofGjzYw83DmEGTPgkH2MUCjjXOzQDsjLzCQEI33yYJdZf9M0T/kyvGMLRZ6rc2X0vr9SlDPB6KW2zGS38w9yyzilWn6z3lqv78Mjc4ESbjUNREjiEgvFHaeydphuh+Llz39ZVo+OAhGVqUHrTaPJL/62IFJJFLAC0v+C+B+/IbbBFrRj9XaxmoW97yoCwzt51EqoLNLvt/j0p3qEaw3dJiWCqZ4/uBZtXgL0RQaCJSn1fbZVUPonuVVqBZTyvrXa3o0rUhyKEOEjiYS0qyelN3r5VsCg+pyUHhc+8kgLUulVASKrKzA33h9ar3Hxx3bCfGx+ul5MxyXV3KumB0lQ=="
    private static let secondCertificate =
        "MIIDGzCCAgOgAwIBAgIUCuEB+muvVKauukDrBoOCfkts+ZswDQYJKoZIhvcNAQELBQAwHTEbMBkGA1UEAwwSbmV0d29yay10cnVzdC50ZXN0MB4XDTI2MDkxMzA2MTQxN1oXDTM2MDkxMDA2MTQxN1owHTEbMBkGA1UEAwwSbmV0d29yay10cnVzdC50ZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtfCnmY10h+wXAo+kDfkH56NtZq5c5E58yxWbyPXN4BZ2/WhlSEVZsgk4raz2sNveklk/bbI5S3eSKiKyRpjgpgeSB3j2IBqllSBMY1UJ7I+7ztNBmXI1hleF9wJEUVKsxWp5VO3F1Q398mwVolrOEhTjrlLS5dUTFdBmD3QMJ0GEMn/x5Jk8FDYvowiTGT8YiK1PE7ZQnes29jU9k7r6cHBKyWObUObDWir8FA+OKDbmuQOS0lR38X192MfmtkExOLDOmbner69iJFe/7hYCo42h8tquwfU3N/F9IsACtmGhUZ9iAG29q7PSRJuxNaRZvsVB7urE23CXBAtXhRI+bQIDAQABo1MwUTAdBgNVHQ4EFgQUd9J6dESze1QoVc0S0BClkmqUA8AwHwYDVR0jBBgwFoAUd9J6dESze1QoVc0S0BClkmqUA8AwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAr7IocoYofN6eEnPRbSCJhG9x30H0MgK2bUhuepoPv7V6/AlW8iu0uAl5qRajJnXbaWlTd4mBSLN3QVsfJ/Ic+k+1Awep+MYgKUk8soXGPlBD5u/AbDYXgX9Cq8BwGWp8GHM7sOAVdghvk6OBgNEXFubYCf6rbogtNlI/Ry2aEv4aauRTQLy4sJxC44Ap1cKUt3brjCV6A2+YR72vVdcqsEQdDtOFe+VV4TtMPlo5EcvtwPTs3vtIjfwXDOc+I7C8wTHf9/TErgSGJ+e+zn0kx9Csi3UDfG2KhssDmCZ+Elj0kDbd8+8Kp5SrTz5jxvNd7m4TYdkiwjJsGIshPKAEBw=="
}
