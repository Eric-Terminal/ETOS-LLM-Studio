import Testing
import Foundation
import Compression
@testable import Shared

@Suite("Worldbook Import Tests")
struct WorldbookImportTests {

    @Test("import SillyTavern worldbook JSON")
    func testImportSillyTavernJSON() throws {
        let json = """
        {
          "name": "测试世界书",
          "entries": {
            "1": {
              "uid": 1,
              "comment": "角色设定",
              "key": ["Alice"],
              "keysecondary": ["tea"],
              "selectiveLogic": "AND_ANY",
              "content": "Alice 喜欢喝红茶。",
              "position": "after",
              "order": 42,
              "constant": false,
              "disable": false,
              "scanDepth": 6,
              "caseSensitive": false,
              "matchWholeWords": true
            }
          }
        }
        """

        let service = WorldbookImportService()
        let data = try #require(json.data(using: .utf8))
        let worldbook = try service.importWorldbook(from: data, fileName: "test.json")

        #expect(worldbook.name == "测试世界书")
        #expect(worldbook.entries.count == 1)

        let entry = try #require(worldbook.entries.first)
        #expect(entry.uid == 1)
        #expect(entry.comment == "角色设定")
        #expect(entry.keys == ["Alice"])
        #expect(entry.secondaryKeys == ["tea"])
        #expect(entry.position == .after)
        #expect(entry.order == 42)
        #expect(entry.scanDepth == 6)
        #expect(entry.matchWholeWords == true)
    }

    @Test("import worldbook from PNG naidata text chunk")
    func testImportPNGWithNaiData() throws {
        let json = """
        {
          "name": "PNG世界书",
          "entries": {
            "9": {
              "uid": 9,
              "key": ["Bob"],
              "content": "Bob 是钟表匠。",
              "position": "before"
            }
          }
        }
        """
        let png = makePNGWithNaiData(json)
        let service = WorldbookImportService()

        let worldbook = try service.importWorldbook(from: png, fileName: "world.png")

        #expect(worldbook.name == "PNG世界书")
        #expect(worldbook.entries.count == 1)
        #expect(worldbook.entries.first?.position == .before)
        #expect(worldbook.entries.first?.content.contains("钟表匠") == true)
    }

    @Test("import worldbook from PNG naidata text chunk with base64 payload (SillyTavern style)")
    func testImportPNGWithBase64NaiData() throws {
        let json = """
        {
          "name": "PNG-BASE64世界书",
          "entries": {
            "12": {
              "uid": 12,
              "key": ["Eva"],
              "content": "这是 base64 naidata。",
              "position": "after"
            }
          }
        }
        """
        let png = makePNGWithBase64NaiData(json)
        let service = WorldbookImportService()

        let worldbook = try service.importWorldbook(from: png, fileName: "world-base64.png")

        #expect(worldbook.name == "PNG-BASE64世界书")
        #expect(worldbook.entries.count == 1)
        #expect(worldbook.entries.first?.content == "这是 base64 naidata。")
    }

    @Test("import worldbook from PNG naidata zTXt chunk")
    func testImportPNGWithNaiDataZTXt() throws {
        let json = """
        {
          "name": "PNG-ZTXT世界书",
          "entries": {
            "3": {
              "uid": 3,
              "key": ["clock"],
              "content": "zTXt 命中。"
            }
          }
        }
        """
        let png = try makePNGWithNaiDataZTXt(json)
        let service = WorldbookImportService()

        let worldbook = try service.importWorldbook(from: png, fileName: "world-ztxt.png")

        #expect(worldbook.name == "PNG-ZTXT世界书")
        #expect(worldbook.entries.count == 1)
        #expect(worldbook.entries.first?.content == "zTXt 命中。")
    }

    @Test("import worldbook from PNG naidata iTXt chunk")
    func testImportPNGWithNaiDataITXt() throws {
        let json = """
        {
          "name": "PNG-ITXT世界书",
          "entries": {
            "5": {
              "uid": 5,
              "key": ["clock"],
              "content": "iTXt 命中。"
            }
          }
        }
        """
        let png = makePNGWithNaiDataITXt(json)
        let service = WorldbookImportService()

        let worldbook = try service.importWorldbook(from: png, fileName: "world-itxt.png")

        #expect(worldbook.name == "PNG-ITXT世界书")
        #expect(worldbook.entries.count == 1)
        #expect(worldbook.entries.first?.content == "iTXt 命中。")
    }

    @Test("import Novel lorebook JSON")
    func testImportNovelJSON() throws {
        let json = """
        {
          "name": "Novel书",
          "lorebookVersion": 3,
          "entries": [
            {
              "id": 11,
              "displayName": "设定A",
              "text": "这是 Novel 条目",
              "keys": ["novel-key"]
            }
          ]
        }
        """
        let service = WorldbookImportService()
        let data = try #require(json.data(using: .utf8))
        let worldbook = try service.importWorldbook(from: data, fileName: "novel.json")
        #expect(worldbook.name == "Novel书")
        #expect(worldbook.entries.count == 1)
        #expect(worldbook.entries.first?.keys == ["novel-key"])
        #expect(worldbook.entries.first?.comment == "设定A")
    }

    @Test("import Agnai memory JSON")
    func testImportAgnaiJSON() throws {
        let json = """
        {
          "name": "Agnai书",
          "kind": "memory",
          "entries": [
            {
              "uid": 2,
              "name": "条目B",
              "value": "Agnai 条目内容",
              "key": ["agnai-key"]
            }
          ]
        }
        """
        let service = WorldbookImportService()
        let data = try #require(json.data(using: .utf8))
        let worldbook = try service.importWorldbook(from: data, fileName: "agnai.json")
        #expect(worldbook.name == "Agnai书")
        #expect(worldbook.entries.count == 1)
        #expect(worldbook.entries.first?.content == "Agnai 条目内容")
        #expect(worldbook.entries.first?.keys == ["agnai-key"])
    }

    @Test("import Risu JSON")
    func testImportRisuJSON() throws {
        let json = """
        {
          "name": "Risu书",
          "type": "risu",
          "entries": [
            {
              "id": 8,
              "name": "条目C",
              "text": "Risu 条目内容",
              "keys": ["risu-key"]
            }
          ]
        }
        """
        let service = WorldbookImportService()
        let data = try #require(json.data(using: .utf8))
        let worldbook = try service.importWorldbook(from: data, fileName: "risu.json")
        #expect(worldbook.name == "Risu书")
        #expect(worldbook.entries.count == 1)
        #expect(worldbook.entries.first?.content == "Risu 条目内容")
        #expect(worldbook.entries.first?.keys == ["risu-key"])
    }

    @Test("import report includes failed entries and reasons")
    func testImportReportIncludesFailures() throws {
        let json = """
        {
          "name": "失败统计书",
          "entries": {
            "1": {"uid": 1, "key": ["ok"], "content": "有效条目"},
            "2": {"uid": 2, "key": ["bad"], "content": ""},
            "3": "not-an-entry"
          }
        }
        """
        let service = WorldbookImportService()
        let data = try #require(json.data(using: .utf8))
        let result = try service.importWorldbookWithReport(from: data, fileName: "with-failures.json")
        #expect(result.worldbook.entries.count == 1)
        #expect(result.diagnostics.failedEntries == 2)
        #expect(result.diagnostics.failureReasons.isEmpty == false)
    }

    @Test("import ST-compatible array entries JSON (rikkahub style)")
    func testImportSTCompatibleArrayJSON() throws {
        let json = """
        {
          "name": "Rikka书",
          "entries": [
            {
              "uid": 21,
              "comment": "Rikka 条目",
              "key": ["rikka"],
              "content": "Rikka 兼容 ST 的条目。",
              "position": "ANTop"
            }
          ]
        }
        """
        let service = WorldbookImportService()
        let data = try #require(json.data(using: .utf8))
        let worldbook = try service.importWorldbook(from: data, fileName: "rikka.json")
        #expect(worldbook.name == "Rikka书")
        #expect(worldbook.entries.count == 1)
        #expect(worldbook.entries.first?.position == .anTop)
        #expect(worldbook.entries.first?.keys == ["rikka"])
    }

    @Test("import top-level entries array JSON")
    func testImportTopLevelArrayJSON() throws {
        let json = """
        [
          {
            "uid": 31,
            "comment": "TopLevel",
            "key": ["array-key"],
            "content": "顶层数组条目。",
            "position": "EMTop"
          }
        ]
        """
        let service = WorldbookImportService()
        let data = try #require(json.data(using: .utf8))
        let worldbook = try service.importWorldbook(from: data, fileName: "top-array.json")
        #expect(worldbook.entries.count == 1)
        #expect(worldbook.entries.first?.position == .emTop)
        #expect(worldbook.entries.first?.keys == ["array-key"])
    }

    @Test("import character card book JSON with character_book entries")
    func testImportCharacterBookJSON() throws {
        let json = """
        {
          "name": "角色卡",
          "character_book": {
            "name": "角色卡世界书",
            "entries": [
              {
                "id": 7,
                "enabled": true,
                "keys": ["hero"],
                "secondary_keys": ["ruby"],
                "content": "角色卡条目内容",
                "insertion_order": 5,
                "position": "before_char",
                "extensions": {
                  "scan_depth": 8,
                  "group_override": true
                }
              }
            ]
          }
        }
        """
        let service = WorldbookImportService()
        let data = try #require(json.data(using: .utf8))
        let worldbook = try service.importWorldbook(from: data, fileName: "character-card.json")
        #expect(worldbook.entries.count == 1)
        #expect(worldbook.entries.first?.position == .before)
        #expect(worldbook.entries.first?.scanDepth == 8)
        #expect(worldbook.entries.first?.groupOverride == true)
    }

    private func makePNGWithNaiData(_ json: String) -> Data {
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10]) // PNG signature

        // IHDR (13 bytes)
        let ihdrBody = Data([
            0, 0, 0, 1, // width = 1
            0, 0, 0, 1, // height = 1
            8, // bit depth
            2, // color type (RGB)
            0, // compression
            0, // filter
            0  // interlace
        ])
        data.append(makeChunk(type: "IHDR", body: ihdrBody))

        // tEXt chunk key=naidata
        var textBody = Data("naidata".utf8)
        textBody.append(0)
        textBody.append(contentsOf: json.utf8)
        data.append(makeChunk(type: "tEXt", body: textBody))

        // IEND
        data.append(makeChunk(type: "IEND", body: Data()))
        return data
    }

    private func makePNGWithBase64NaiData(_ json: String) -> Data {
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10]) // PNG signature

        let ihdrBody = Data([
            0, 0, 0, 1,
            0, 0, 0, 1,
            8, 2, 0, 0, 0
        ])
        data.append(makeChunk(type: "IHDR", body: ihdrBody))

        let base64 = Data(json.utf8).base64EncodedString()
        var textBody = Data("naidata".utf8)
        textBody.append(0)
        textBody.append(contentsOf: base64.utf8)
        data.append(makeChunk(type: "tEXt", body: textBody))

        data.append(makeChunk(type: "IEND", body: Data()))
        return data
    }

    private func makePNGWithNaiDataZTXt(_ json: String) throws -> Data {
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10]) // PNG signature

        let ihdrBody = Data([
            0, 0, 0, 1,
            0, 0, 0, 1,
            8, 2, 0, 0, 0
        ])
        data.append(makeChunk(type: "IHDR", body: ihdrBody))

        let compressed = try #require(zlibCompress(Data(json.utf8)))
        var ztxtBody = Data("naidata".utf8)
        ztxtBody.append(0) // keyword end
        ztxtBody.append(0) // compression method (zlib)
        ztxtBody.append(compressed)
        data.append(makeChunk(type: "zTXt", body: ztxtBody))

        data.append(makeChunk(type: "IEND", body: Data()))
        return data
    }

    private func makePNGWithNaiDataITXt(_ json: String) -> Data {
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10]) // PNG signature

        let ihdrBody = Data([
            0, 0, 0, 1,
            0, 0, 0, 1,
            8, 2, 0, 0, 0
        ])
        data.append(makeChunk(type: "IHDR", body: ihdrBody))

        var itxtBody = Data("naidata".utf8)
        itxtBody.append(0) // keyword end
        itxtBody.append(0) // compression flag: uncompressed
        itxtBody.append(0) // compression method
        itxtBody.append(0) // language tag end
        itxtBody.append(0) // translated keyword end
        itxtBody.append(contentsOf: json.utf8)
        data.append(makeChunk(type: "iTXt", body: itxtBody))

        data.append(makeChunk(type: "IEND", body: Data()))
        return data
    }

    private func zlibCompress(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        var capacity = max(4096, input.count * 2)
        let maxCapacity = max(8192, input.count * 16)

        while capacity <= maxCapacity {
            var output = Data(count: capacity)
            let encodedCount = output.withUnsafeMutableBytes { outputRaw in
                input.withUnsafeBytes { inputRaw in
                    guard let dst = outputRaw.bindMemory(to: UInt8.self).baseAddress,
                          let src = inputRaw.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return compression_encode_buffer(dst, capacity, src, input.count, nil, COMPRESSION_ZLIB)
                }
            }

            if encodedCount > 0 {
                output.count = encodedCount
                return output
            }
            capacity *= 2
        }

        return nil
    }

    private func makeChunk(type: String, body: Data) -> Data {
        var chunk = Data()
        var length = UInt32(body.count).bigEndian
        chunk.append(Data(bytes: &length, count: 4))
        chunk.append(contentsOf: type.utf8)
        chunk.append(body)
        chunk.append(Data([0, 0, 0, 0])) // CRC 占位
        return chunk
    }
}
