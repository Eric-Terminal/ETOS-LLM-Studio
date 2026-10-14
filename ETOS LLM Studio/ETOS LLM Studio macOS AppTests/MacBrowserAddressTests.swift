import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacBrowserAddressTests {
    @Test("地址保留查询编码，裸域名使用 HTTPS")
    func explicitAndImplicitURLs() throws {
        #expect(try MacBrowserAddress.resolve(" example.com/path?q=one%20two ").absoluteString == "https://example.com/path?q=one%20two")
        #expect(try MacBrowserAddress.resolve("http://localhost:8080/test").scheme == "http")
    }

    @Test("搜索词通过查询项编码，不拼接新的 URL 参数")
    func searchKeepsQueryAsOneValue() throws {
        let url = try MacBrowserAddress.resolve("中文 & other=secret # fragment")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "www.google.com")
        #expect(components.queryItems?.count == 1 && components.queryItems?.first?.value == "中文 & other=secret # fragment")
        #expect(components.fragment == nil)
    }

    @Test("空输入与非网页协议不交给 WebKit")
    func rejectsUnsupportedURLs() {
        for input in [" \n ", "file:///tmp/private", "ftp://example.com", "custom://open", "https://"] {
            #expect(throws: BrowserAgentError.self) { try MacBrowserAddress.resolve(input) }
        }
    }
}
