import Foundation
import Testing
@testable import ETOSCore

@Suite("本地调试 SQLite 参数校验")
struct LocalDebugServerSQLiteTests {
    @Test("缺失、null 和空数组均表示没有绑定参数", arguments: [
        #"{}"#,
        #"{"parameters":null}"#,
        #"{"parameters":[]}"#
    ])
    func acceptsEmptyParameters(commandJSON: String) throws {
        let command = try #require(
            JSONSerialization.jsonObject(with: Data(commandJSON.utf8)) as? [String: Any]
        )
        #expect(try LocalDebugServer.decodeDebugSQLiteParameters(command["parameters"]).isEmpty)
    }

    @Test("参数数组保留绑定顺序以及字符串、数值、布尔和空值类型")
    func preservesParameterValues() throws {
        let command = try #require(JSONSerialization.jsonObject(
            with: Data(#"{"parameters":["中文",7,2.5,true,false,null]}"#.utf8)
        ) as? [String: Any])
        let parameters = try LocalDebugServer.decodeDebugSQLiteParameters(command["parameters"])
        #expect(parameters == [.string("中文"), .int(7), .double(2.5), .bool(true), .bool(false), .null])
    }

    @Test("非数组参数抛出可捕获错误而非终止进程", arguments: [
        #"{"parameters":"[]"}"#,
        #"{"parameters":1}"#,
        #"{"parameters":true}"#,
        #"{"parameters":{}}"#
    ])
    func rejectsNonArrayParameters(commandJSON: String) throws {
        let command = try #require(
            JSONSerialization.jsonObject(with: Data(commandJSON.utf8)) as? [String: Any]
        )
        #expect(throws: AppToolExecutionError.self) {
            try LocalDebugServer.decodeDebugSQLiteParameters(command["parameters"])
        }
    }

    @MainActor
    @Test("查询与写入入口在执行 SQL 前返回参数类型错误", arguments: ["query_sqlite", "mutate_sqlite"])
    func handlersRejectInvalidParameters(command: String) async {
        let server = LocalDebugServer()
        let request: [String: Any] = [
            "database": "chat",
            // SQL 故意无效，确保返回的是参数校验错误，且不依赖数据库是否已初始化。
            "sql": "无效 SQL",
            "parameters": "[]"
        ]
        let response: [String: Any]
        if command == "query_sqlite" {
            response = await server.handleSQLiteQuery(request)
        } else {
            response = await server.handleSQLiteMutate(request)
        }
        #expect(response["status"] as? String == "error")
        #expect(response["error_code"] as? String == "INVALID_ARGS")
        #expect(response["message"] as? String == NSLocalizedString(
            "SQLite parameters 必须是 JSON 数组。",
            value: "SQLite parameters must be a JSON array.",
            comment: "SQLite 调试命令参数类型错误"
        ))
    }
}
