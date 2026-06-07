package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/charmbracelet/bubbles/table"
)

func (m *tuiModel) applyFiles(response map[string]any) {
	items := asMapSlice(response["items"])
	rows := make([]table.Row, 0, len(items))
	for _, item := range items {
		kind := "文件"
		if asBool(item["isDirectory"]) {
			kind = "目录"
		}
		rows = append(rows, table.Row{
			asString(item["name"]),
			kind,
			formatSize(int64(asInt(item["size"]))),
			time.Unix(int64(asFloat64(item["modificationDate"])), 0).Format("2006-01-02 15:04"),
		})
	}
	m.fileItems = items
	m.filesTable.SetRows(rows)
	m.setMessage(fmt.Sprintf("已加载 %d 个项目", len(rows)), tuiOKStyle)
}

func (m *tuiModel) applyReadFile(path string, response map[string]any) {
	data, err := base64.StdEncoding.DecodeString(asString(response["data"]))
	if err != nil {
		m.setMessage("Base64 解码失败: "+err.Error(), tuiErrStyle)
		return
	}
	localPath := filepath.Join("downloads", filepath.Base(path))
	if err := os.MkdirAll(filepath.Dir(localPath), 0o755); err != nil {
		m.setMessage(err.Error(), tuiErrStyle)
		return
	}
	if err := os.WriteFile(localPath, data, 0o644); err != nil {
		m.setMessage(err.Error(), tuiErrStyle)
		return
	}
	if text := previewText(data); text != "" {
		m.preview.SetValue(text)
	} else {
		m.preview.SetValue(fmt.Sprintf("二进制文件已保存: %s (%s)", localPath, formatSize(int64(len(data)))))
	}
	m.setMessage("已保存到 "+localPath, tuiOKStyle)
}

func (m *tuiModel) applyProviders(response map[string]any) {
	providers := asMapSlice(response["providers"])
	rows := make([]table.Row, 0, len(providers))
	for _, provider := range providers {
		rows = append(rows, table.Row{
			asString(provider["id"]),
			asString(provider["name"]),
			asString(provider["apiFormat"]),
			fmt.Sprintf("%d", len(asAnySlice(provider["models"]))),
			asString(provider["baseURL"]),
		})
	}
	m.providerRows = providers
	m.providers.SetColumns([]table.Column{{Title: "ID", Width: 36}, {Title: "名称", Width: 22}, {Title: "格式", Width: 18}, {Title: "模型", Width: 8}, {Title: "API URL", Width: 36}})
	m.providers.SetRows(rows)
	m.setMessage(fmt.Sprintf("已加载 %d 个提供商", len(rows)), tuiOKStyle)
}

func (m *tuiModel) applySettings(response map[string]any) {
	settings := asMapSlice(response["settings"])
	rows := make([]table.Row, 0, len(settings))
	for _, setting := range settings {
		rows = append(rows, table.Row{
			asString(setting["key"]),
			asString(setting["group"]),
			asString(setting["type"]),
			boolLabel(asBool(setting["participates_in_sync"])),
			truncateLine(asString(setting["value_text"]), 72),
		})
	}
	m.settingRows = settings
	m.settings.SetRows(rows)
	m.setMessage(fmt.Sprintf("已加载 %d 项配置", len(rows)), tuiOKStyle)
}

func (m *tuiModel) applySessions(response map[string]any) {
	sessions := asMapSlice(response["sessions"])
	rows := make([]table.Row, 0, len(sessions))
	for _, session := range sessions {
		rows = append(rows, table.Row{
			asString(session["id"]),
			asString(session["name"]),
			sessionInfoText(session),
		})
	}
	m.sessionRows = sessions
	m.sessionMode = tuiSessionModeList
	m.sessions.SetRows(rows)
	m.setMessage(fmt.Sprintf("已加载 %d 个会话；按 Enter 查看消息", len(rows)), tuiOKStyle)
}

func (m *tuiModel) applyMemories(response map[string]any) {
	memories := asMapSlice(response["memories"])
	rows := make([]table.Row, 0, len(memories))
	for _, memory := range memories {
		status := "活跃"
		if asBool(memory["isArchived"]) || asBool(memory["is_archived"]) {
			status = "归档"
		}
		rows = append(rows, table.Row{
			asString(memory["id"]),
			status,
			truncateLine(asString(memory["content"]), 80),
		})
	}
	m.memoryRows = memories
	m.memories.SetRows(rows)
	m.setMessage(fmt.Sprintf("已加载 %d 条记忆", len(rows)), tuiOKStyle)
}

func (m *tuiModel) applySQLiteTables(response map[string]any) {
	tables := asMapSlice(response["tables"])
	rows := make([]table.Row, 0, len(tables))
	for _, item := range tables {
		rows = append(rows, table.Row{
			asString(item["name"]),
			asString(item["type"]),
			fmt.Sprintf("%d", asInt(item["columnCount"])),
		})
	}
	m.sqlTables.SetRows(rows)
	m.sqlRows.SetRows([]table.Row{})
	m.preview.SetValue(prettyJSON(response))
	m.setMessage(fmt.Sprintf("已加载 %s 库 %d 张表", m.sqlDatabase, len(rows)), tuiOKStyle)
}

func (m *tuiModel) applySQLiteRows(response map[string]any) {
	columns := asStringSlice(response["columns"])
	rowsRaw := asMapSlice(response["rows"])
	if len(columns) == 0 {
		m.sqlRows.SetColumns([]table.Column{{Title: "结果", Width: 90}})
		m.sqlRows.SetRows([]table.Row{{prettyJSON(response)}})
		m.preview.SetValue(prettyJSON(response))
		return
	}
	cols := make([]table.Column, 0, len(columns))
	for _, name := range columns {
		cols = append(cols, table.Column{Title: name, Width: 18})
	}
	rows := make([]table.Row, 0, len(rowsRaw))
	for _, item := range rowsRaw {
		row := make(table.Row, 0, len(columns))
		for _, name := range columns {
			row = append(row, truncateLine(asString(item[name]), 40))
		}
		rows = append(rows, row)
	}
	m.sqlRows.SetColumns(cols)
	m.sqlRows.SetRows(rows)
	m.preview.SetValue(prettyJSON(response))
	m.setMessage(fmt.Sprintf("查询返回 %d 行", len(rows)), tuiOKStyle)
}

func (m *tuiModel) applyCaptures(response map[string]any) {
	queue := asMapSlice(response["queue"])
	rows := make([]table.Row, 0, len(queue))
	for _, item := range queue {
		rows = append(rows, table.Row{
			asString(item["id"]),
			asString(item["model"]),
			fmt.Sprintf("%d", asInt(item["message_count"])),
			asString(item["received_at"]),
		})
	}
	m.captureRows = queue
	m.captures.SetRows(rows)
	m.setMessage(fmt.Sprintf("捕获队列 %d 条", len(rows)), tuiOKStyle)
}
