import Testing
import Foundation
@testable import Shared

@Suite("Shortcut Import Manifest Tests")
struct ShortcutImportManifestTests {

    @Test("light manifest decodes with names")
    func testDecodeLightManifest() throws {
        let json = """
        {
          "type": "light",
          "data": ["工具A", "工具B"]
        }
        """
        let manifest = try JSONDecoder().decode(ShortcutLightImportManifest.self, from: Data(json.utf8))
        #expect(manifest.type == .light)
        #expect(manifest.data.count == 2)
        #expect(manifest.data.first == "工具A")
    }

    @Test("deep manifest decodes link and url key")
    func testDecodeDeepManifest() throws {
        let json = """
        {
          "type": "deep",
          "data": [
            {"name": "工具A", "link": "https://www.icloud.com/shortcuts/abc"},
            {"name": "工具B", "url": "https://www.icloud.com/shortcuts/def"}
          ]
        }
        """
        let manifest = try JSONDecoder().decode(ShortcutDeepImportManifest.self, from: Data(json.utf8))
        #expect(manifest.type == .deep)
        #expect(manifest.data.count == 2)
        #expect(manifest.data[0].link.contains("/abc"))
        #expect(manifest.data[1].link.contains("/def"))
    }
}
