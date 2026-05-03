// ============================================================================
// AppToolKindDescriptions.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具发送给模型的自然语言说明。
// ============================================================================

import Foundation

extension AppToolKind {
    public var toolDescription: String {
        switch self {
        case .showWidget:
            return NSLocalizedString(
                "把传入的 HTML Widget 渲染为聊天内联网页卡片。title 可选，widget_code 必填，loading_messages 可选。",
                comment: "Show widget tool description sent to model"
            )
        case .askUserInput:
            return NSLocalizedString(
                "向用户展示结构化问答面板。支持 single_select / multi_select、可选的“其他输入”、必填校验与自定义提交按钮文案。此工具用于在回答前收集关键信息，调用后应等待用户补充。",
                comment: "Ask user input tool description sent to model"
            )
        case .getSystemTime:
            return NSLocalizedString(
                "获取当前设备系统时间。无需参数；当用户询问当前时间、日期或需要实时本地时间线索时调用。",
                comment: "Get system time tool description sent to model"
            )
        case .echoText:
            return NSLocalizedString(
                "示例工具：把 text 参数中的文本原样返回，仅用于验证本地拓展工具链路与参数生成是否正常。",
                comment: "Example echo tool description sent to model"
            )
        case .fillUserInput:
            return NSLocalizedString(
                "把文本放入用户当前聊天输入框。text 为要填入的内容；mode=replace 会覆盖输入框，mode=append 会追加到末尾。适合为用户准备可编辑的草稿，而不是直接代替用户发送。",
                comment: "Fill user input tool description sent to model"
            )
        case .editMemory:
            return NSLocalizedString(
                "编辑既有长期记忆。可按 memory_id 修改 content，也可切换归档状态。修改 content 后会自动重新生成这条记忆的嵌入。",
                comment: "Memory edit tool description sent to model"
            )
        case .submitFeedbackTicket:
            return NSLocalizedString(
                "向反馈助手提交一条问题或建议工单。title 和 detail 必填；category 可选 bug 或 suggestion（默认 bug）；可附带复现步骤、预期行为、实际行为、补充信息。",
                comment: "Submit feedback ticket tool description sent to model"
            )
        case .listSandboxDirectory:
            return NSLocalizedString(
                "查看应用沙盒 Documents 目录中的文件与子目录。path 留空时表示根目录，只能访问沙盒内部路径。",
                comment: "List sandbox directory description sent to model"
            )
        case .readSandboxFile:
            return NSLocalizedString(
                "读取应用沙盒 Documents 目录中的 UTF-8 文本文件。只能访问沙盒内部路径。",
                comment: "Read sandbox file description sent to model"
            )
        case .writeSandboxFile:
            return NSLocalizedString(
                "写入或覆盖应用沙盒 Documents 目录中的 UTF-8 文本文件。只能访问沙盒内部路径。",
                comment: "Write sandbox file description sent to model"
            )
        case .searchSandboxFiles:
            return NSLocalizedString(
                "按路径名或 UTF-8 文本内容搜索应用沙盒 Documents 目录下的文件。只能访问沙盒内部路径。",
                comment: "Search sandbox files description sent to model"
            )
        case .readSandboxFileChunk:
            return NSLocalizedString(
                "按行号分块读取应用沙盒 Documents 目录中的 UTF-8 文本文件，适合大文件场景。只能访问沙盒内部路径。",
                comment: "Read sandbox file chunk description sent to model"
            )
        case .moveSandboxItem:
            return NSLocalizedString(
                "在应用沙盒 Documents 目录内移动或重命名文件、子目录。只能访问沙盒内部路径。",
                comment: "Move sandbox item description sent to model"
            )
        case .copySandboxItem:
            return NSLocalizedString(
                "在应用沙盒 Documents 目录内复制文件或子目录，可选是否覆盖已有路径。只能访问沙盒内部路径。",
                comment: "Copy sandbox item description sent to model"
            )
        case .createSandboxDirectory:
            return NSLocalizedString(
                "在应用沙盒 Documents 目录内创建目录，可选自动创建父目录。只能访问沙盒内部路径。",
                comment: "Create sandbox directory description sent to model"
            )
        case .batchEditSandboxFile:
            return NSLocalizedString(
                "按多条规则批量编辑应用沙盒 Documents 目录中的 UTF-8 文本文件。只能访问沙盒内部路径。",
                comment: "Batch edit sandbox file description sent to model"
            )
        case .listMemories:
            return NSLocalizedString(
                "分页列出长期记忆并支持关键词筛选，可选择是否包含归档记忆。",
                comment: "List memories description sent to model"
            )
        case .listSQLiteTables:
            return NSLocalizedString(
                "列出指定 SQLite 数据库（chat/config/memory）的表与字段结构，可选返回建表 SQL。",
                comment: "List SQLite tables description sent to model"
            )
        case .querySQLite:
            return NSLocalizedString(
                "执行只读 SQL 查询。database 选择 chat/config/memory；sql 仅支持 SELECT/WITH/PRAGMA 且必须是单条语句；parameters 可选，用于按顺序绑定 ? 占位符；max_rows 默认 50。",
                comment: "Query SQLite description sent to model"
            )
        case .mutateSQLite:
            return NSLocalizedString(
                "执行写入 SQL。database 选择 chat/config/memory；sql 仅支持 INSERT/UPDATE/DELETE/REPLACE 且必须是单条语句；parameters 可选；UPDATE/DELETE 默认要求带 WHERE，除非 allow_without_where=true。",
                comment: "Mutate SQLite description sent to model"
            )
        case .undoSandboxMutation:
            return NSLocalizedString(
                "撤销最近一次由拓展工具造成的沙盒文件修改。",
                comment: "Undo sandbox mutation description sent to model"
            )
        case .diffSandboxFile:
            return NSLocalizedString(
                "比较应用沙盒 Documents 目录中文本文件的当前内容与拟修改内容之间的差异，只能访问沙盒内部路径。",
                comment: "Diff sandbox file description sent to model"
            )
        case .editSandboxFile:
            return NSLocalizedString(
                "按旧文本和新文本对应用沙盒 Documents 目录中的 UTF-8 文本文件做局部替换。只能访问沙盒内部路径。",
                comment: "Edit sandbox file description sent to model"
            )
        case .deleteSandboxItem:
            return NSLocalizedString(
                "删除应用沙盒 Documents 目录中的文件或子目录。只能访问沙盒内部路径，不能删除 Documents 根目录。",
                comment: "Delete sandbox item description sent to model"
            )
        }
    }
}
