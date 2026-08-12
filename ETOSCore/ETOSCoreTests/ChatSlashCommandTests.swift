// ============================================================================
// ChatSlashCommandTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件验证斜杠命令筛选、完整识别与未知内容透传边界。
// ============================================================================

import XCTest
@testable import ETOSCore

final class ChatSlashCommandTests: XCTestCase {
    func testSlashDisplaysAllCommandsInPresentationOrder() {
        let suggestions = ChatSlashCommandParser.suggestions(for: "/")

        XCTAssertEqual(suggestions, ChatSlashCommand.allCases)
        XCTAssertEqual(suggestions.first, .new)
    }

    func testPrefixFiltersToUsage() {
        XCTAssertEqual(ChatSlashCommandParser.suggestions(for: "/us"), [.usage])
    }

    func testPrefixOnlyMatchesDisplayedCommandName() {
        XCTAssertEqual(
            ChatSlashCommandParser.suggestions(for: "/s"),
            [.sessions, .settings, .skills, .shortcuts, .stop]
        )
        XCTAssertFalse(ChatSlashCommandParser.suggestions(for: "/s").contains(.usage))
        XCTAssertTrue(ChatSlashCommandParser.suggestions(for: "/hist").isEmpty)
    }

    func testCompleteAliasStillResolvesCanonicalCommand() {
        XCTAssertEqual(ChatSlashCommandParser.recognizedCommand(in: "/history"), .sessions)
        XCTAssertEqual(ChatSlashCommandParser.recognizedCommand(in: "/stats"), .usage)
    }

    func testCompleteCommandIsRecognizedCaseInsensitively() {
        XCTAssertEqual(ChatSlashCommandParser.recognizedCommand(in: "/NEW"), .new)
        XCTAssertEqual(ChatSlashCommandParser.recognizedCommand(in: "/usage\n"), .usage)
    }

    func testUnknownPathRemainsUnrecognized() {
        XCTAssertNil(ChatSlashCommandParser.recognizedCommand(in: "/Users/Eric/file.txt"))
        XCTAssertTrue(ChatSlashCommandParser.suggestions(for: "/Users/Eric/file.txt").isEmpty)
    }

    func testUnknownCommandAndArgumentsRemainUnrecognized() {
        XCTAssertNil(ChatSlashCommandParser.recognizedCommand(in: "/unknown"))
        XCTAssertNil(ChatSlashCommandParser.recognizedCommand(in: "/new later"))
    }

    func testSlashMustStartAtBeginningOfMessage() {
        XCTAssertNil(ChatSlashCommandParser.recognizedCommand(in: " /new"))
        XCTAssertTrue(ChatSlashCommandParser.suggestions(for: " /new").isEmpty)
    }

    func testFeatureIsDisabledByDefault() {
        XCTAssertEqual(AppConfigKey.enableSlashCommands.defaultValue, .bool(false))
    }

    func testCustomCommandAppearsInPrefixSuggestions() {
        let customCommand = CustomChatSlashCommand(trigger: "sk", prompt: "请总结当前对话。")

        let suggestions = ChatSlashCommandParser.suggestions(
            for: "/sk",
            customCommands: [customCommand]
        )

        XCTAssertTrue(suggestions.contains(.builtIn(.skills)))
        XCTAssertTrue(suggestions.contains(.custom(customCommand)))
    }

    func testCustomCommandRecognitionIsCaseInsensitive() {
        let customCommand = CustomChatSlashCommand(trigger: "sk", prompt: "请总结当前对话。")

        XCTAssertEqual(
            ChatSlashCommandParser.recognizedCustomCommand(
                in: "/SK\n",
                customCommands: [customCommand]
            ),
            customCommand
        )
    }

    func testBuiltInNamesAndAliasesAreReserved() {
        XCTAssertTrue(ChatSlashCommandParser.isReservedTrigger("new"))
        XCTAssertTrue(ChatSlashCommandParser.isReservedTrigger("history"))
        XCTAssertFalse(ChatSlashCommandParser.isReservedTrigger("sk"))
    }

    func testCustomTriggerNormalizationAcceptsLeadingSlash() {
        XCTAssertEqual(CustomChatSlashCommandStore.canonicalTrigger(" /SK "), "sk")
        XCTAssertTrue(CustomChatSlashCommandStore.isValidTrigger("story-kit_2"))
        XCTAssertFalse(CustomChatSlashCommandStore.isValidTrigger("story kit"))
    }
}
