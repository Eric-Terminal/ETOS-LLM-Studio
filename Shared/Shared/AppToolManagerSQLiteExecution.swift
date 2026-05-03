// ============================================================================
// AppToolManagerSQLiteExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具中的 SQLite 表结构、查询与写入执行入口。
// ============================================================================

import Foundation

extension AppToolManager {
    func executeListSQLiteTables(argumentsJSON: String) async throws -> String {
        struct ListSQLiteTablesArgs: Decodable {
            let database: String
            let include_internal: Bool?
            let include_create_sql: Bool?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(ListSQLiteTablesArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 list_sqlite_tables 的参数，请提供 database。", comment: "List SQLite tables invalid arguments")
            )
        }

        guard let database = Self.parseSQLiteDatabase(rawValue: args.database) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：list_sqlite_tables 的 database 必须是 chat、config 或 memory。", comment: "List SQLite tables invalid database")
            )
        }

        do {
            let payload = try await Self.runSQLiteOperationOffMainThread {
                try Self.listSQLiteTables(
                    in: database,
                    includeInternal: args.include_internal ?? false,
                    includeCreateSQL: args.include_create_sql ?? false
                )
            }
            return prettyPrintedJSONString(from: payload)
        } catch let appToolError as AppToolExecutionError {
            throw appToolError
        } catch {
            throw AppToolExecutionError.invalidArguments(
                String(
                    format: NSLocalizedString("错误：list_sqlite_tables 执行失败：%@", comment: "List SQLite tables execution error"),
                    error.localizedDescription
                )
            )
        }
    }

    func executeQuerySQLite(argumentsJSON: String) async throws -> String {
        struct QuerySQLiteArgs: Decodable {
            let database: String
            let sql: String
            let parameters: [JSONValue]?
            let max_rows: Int?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(QuerySQLiteArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 query_sqlite 的参数，请提供 database 和 sql。", comment: "Query SQLite invalid arguments")
            )
        }

        guard let database = Self.parseSQLiteDatabase(rawValue: args.database) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：query_sqlite 的 database 必须是 chat、config 或 memory。", comment: "Query SQLite invalid database")
            )
        }

        let maxRows = Self.sanitizedSQLiteMaxRows(args.max_rows)
        do {
            let payload = try await Self.runSQLiteOperationOffMainThread {
                try Self.querySQLite(
                    in: database,
                    sql: args.sql,
                    parameters: args.parameters ?? [],
                    maxRows: maxRows
                )
            }
            return prettyPrintedJSONString(from: payload)
        } catch let appToolError as AppToolExecutionError {
            throw appToolError
        } catch {
            throw AppToolExecutionError.invalidArguments(
                String(
                    format: NSLocalizedString("错误：query_sqlite 执行失败：%@", comment: "Query SQLite execution error"),
                    error.localizedDescription
                )
            )
        }
    }

    func executeMutateSQLite(argumentsJSON: String) async throws -> String {
        struct MutateSQLiteArgs: Decodable {
            let database: String
            let sql: String
            let parameters: [JSONValue]?
            let allow_without_where: Bool?
            let returning_max_rows: Int?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(MutateSQLiteArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 mutate_sqlite 的参数，请提供 database 和 sql。", comment: "Mutate SQLite invalid arguments")
            )
        }

        guard let database = Self.parseSQLiteDatabase(rawValue: args.database) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：mutate_sqlite 的 database 必须是 chat、config 或 memory。", comment: "Mutate SQLite invalid database")
            )
        }

        let returningMaxRows = Self.sanitizedSQLiteMaxRows(args.returning_max_rows)
        do {
            let payload = try await Self.runSQLiteOperationOffMainThread {
                try Self.mutateSQLite(
                    in: database,
                    sql: args.sql,
                    parameters: args.parameters ?? [],
                    allowWithoutWhere: args.allow_without_where ?? false,
                    returningMaxRows: returningMaxRows
                )
            }
            return prettyPrintedJSONString(from: payload)
        } catch let appToolError as AppToolExecutionError {
            throw appToolError
        } catch {
            throw AppToolExecutionError.invalidArguments(
                String(
                    format: NSLocalizedString("错误：mutate_sqlite 执行失败：%@", comment: "Mutate SQLite execution error"),
                    error.localizedDescription
                )
            )
        }
    }
}
