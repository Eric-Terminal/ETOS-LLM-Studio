// ============================================================================
// WorldbookStoreTests.swift
// ============================================================================
// WorldbookStoreTests 测试文件
// - 覆盖世界书目录化存储与旧版迁移逻辑
// - 保障单文件保存和兼容读取的稳定性
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("世界书存储测试")
struct WorldbookStoreTests {

    @Test("按单文件保存世界书")
    func testSaveWorldbooksAsStandaloneFiles() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = WorldbookStore(storageDirectoryURL: directory)
        let first = Worldbook(
            id: UUID(),
            name: "海港设定",
            updatedAt: Date(timeIntervalSince1970: 20),
            entries: [WorldbookEntry(content: "港口终年有雾。", keys: ["海港"])]
        )
        let second = Worldbook(
            id: UUID(),
            name: "钟楼设定",
            updatedAt: Date(timeIntervalSince1970: 10),
            entries: [WorldbookEntry(content: "钟楼每天正午鸣响。", keys: ["钟楼"])]
        )

        store.saveWorldbooks([first, second])

        let jsonFiles = try jsonFileNames(in: directory)
        #expect(jsonFiles.count == 2)
        #expect(!jsonFiles.contains(WorldbookStore.fileName))
        #expect(jsonFiles.contains(where: { $0.contains("海港设定") }))
        #expect(jsonFiles.contains(where: { $0.contains("钟楼设定") }))

        let loaded = store.loadWorldbooks()
        #expect(Set(loaded.map(\.id)) == Set([first.id, second.id]))
    }

    @Test("读取旧聚合文件后自动迁移")
    func testLegacyAggregateFileMigratesToStandaloneFiles() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyURL = directory.appendingPathComponent(WorldbookStore.fileName, isDirectory: false)
        let legacyBook = Worldbook(
            id: UUID(),
            name: "旧格式世界书",
            updatedAt: Date(timeIntervalSince1970: 30),
            entries: [WorldbookEntry(content: "这是旧版聚合文件中的条目。", keys: ["旧格式"])]
        )
        let encoder = makeWorldbookEncoder()
        let legacyData = try encoder.encode([legacyBook])
        try legacyData.write(to: legacyURL, options: .atomic)

        let store = WorldbookStore(storageDirectoryURL: directory)
        let loaded = store.loadWorldbooks()

        #expect(loaded.count == 1)
        #expect(loaded.first?.id == legacyBook.id)
        #expect(loaded.first?.name == "旧格式世界书")
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == false)

        let jsonFiles = try jsonFileNames(in: directory)
        #expect(jsonFiles.count == 1)
        #expect(jsonFiles.allSatisfy { $0 != WorldbookStore.fileName })

        let migratedURL = try #require(
            try FileManager.default
                .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .first(where: { $0.pathExtension.lowercased() == "json" })
        )
        let decoder = makeWorldbookDecoder()
        let migrated = try decoder.decode(Worldbook.self, from: Data(contentsOf: migratedURL))
        #expect(migrated.id == legacyBook.id)
        #expect(migrated.entries.count == 1)
    }

    @Test("目录中的外部世界书JSON可直接读取并转存")
    func testExternalWorldbookJSONInDirectoryLoadsAndRewrites() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let importedURL = directory.appendingPathComponent("downloaded-worldbook.json", isDirectory: false)
        let json = """
        {
          "name": "目录导入世界书",
          "entries": {
            "1": {
              "uid": 1,
              "comment": "目录导入条目",
              "key": ["路灯"],
              "content": "这里的路灯会在雾里发蓝光。",
              "position": "after"
            }
          }
        }
        """
        try #require(json.data(using: .utf8)).write(to: importedURL, options: .atomic)

        let store = WorldbookStore(storageDirectoryURL: directory)
        let loaded = store.loadWorldbooks()

        let worldbook = try #require(loaded.first)
        #expect(loaded.count == 1)
        #expect(worldbook.name == "目录导入世界书")
        #expect(worldbook.entries.count == 1)

        let jsonFiles = try jsonFileNames(in: directory)
        #expect(jsonFiles == ["downloaded-worldbook.json"])

        let decoder = makeWorldbookDecoder()
        let persisted = try decoder.decode(Worldbook.self, from: Data(contentsOf: importedURL))
        #expect(persisted.id == worldbook.id)
        #expect(persisted.sourceFileName == "downloaded-worldbook.json")
        #expect(persisted.entries.first?.content == "这里的路灯会在雾里发蓝光。")
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-store-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func jsonFileNames(in directory: URL) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }
            .map(\.lastPathComponent)
            .sorted()
    }

    private func makeWorldbookEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeWorldbookDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
