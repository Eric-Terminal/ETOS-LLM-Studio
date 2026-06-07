package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/table"
	"github.com/charmbracelet/bubbles/textarea"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"
)

type tuiView int

const (
	tuiDashboard tuiView = iota
	tuiFiles
	tuiProviders
	tuiSessions
	tuiMemories
	tuiSQLite
	tuiCaptures
)

type navItem struct {
	title string
	desc  string
	view  tuiView
}

func (i navItem) Title() string       { return i.title }
func (i navItem) Description() string { return i.desc }
func (i navItem) FilterValue() string { return i.title + " " + i.desc }

type tuiTickMsg time.Time

type tuiCommandResultMsg struct {
	op       string
	response map[string]any
	err      error
}

type tuiStatus struct {
	connected       bool
	mode            string
	deviceName      string
	queueSize       int
	pendingRequests int
}

type tuiModel struct {
	server  *DebugServer
	localIP string

	width  int
	height int
	active tuiView

	nav        list.Model
	spinner    spinner.Model
	filesTable table.Model
	providers  table.Model
	sessions   table.Model
	memories   table.Model
	sqlTables  table.Model
	sqlRows    table.Model
	captures   table.Model
	preview    textarea.Model

	status       tuiStatus
	currentPath  string
	sqlDatabase  string
	isLoading    bool
	message      string
	messageStyle lipgloss.Style

	fileItems    []map[string]any
	providerRows []map[string]any
	sessionRows  []map[string]any
	memoryRows   []map[string]any
	captureRows  []map[string]any
}

var (
	tuiTitleStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("75"))
	tuiBoxStyle   = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("240")).
			Padding(0, 1)
	tuiHelpStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	tuiOKStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("42"))
	tuiWarnStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("214"))
	tuiErrStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("203"))
)

func newTUIModel(server *DebugServer, localIP string) tuiModel {
	navItems := []list.Item{
		navItem{"总览", "连接状态、端口与操作提示", tuiDashboard},
		navItem{"文件", "浏览、下载、删除、创建目录", tuiFiles},
		navItem{"提供商", "查看提供商，新增 API 与模型", tuiProviders},
		navItem{"会话", "懒加载会话详情，创建与删除", tuiSessions},
		navItem{"记忆", "编辑、归档与重嵌入", tuiMemories},
		navItem{"SQLite", "表结构、查询与写入 SQL", tuiSQLite},
		navItem{"捕获", "OpenAI 捕获队列保存/忽略", tuiCaptures},
	}
	delegate := list.NewDefaultDelegate()
	delegate.ShowDescription = true
	nav := list.New(navItems, delegate, 28, 18)
	nav.Title = "ETOS 调试工具"
	nav.SetShowStatusBar(false)
	nav.SetFilteringEnabled(false)
	nav.SetShowHelp(false)

	spin := spinner.New()
	spin.Spinner = spinner.Dot

	preview := textarea.New()
	preview.Placeholder = "这里会显示详情、查询结果或操作反馈"
	preview.ShowLineNumbers = false
	preview.SetHeight(14)
	preview.SetWidth(80)

	model := tuiModel{
		server:       server,
		localIP:      localIP,
		nav:          nav,
		spinner:      spin,
		filesTable:   newTUITable([]table.Column{{Title: "名称", Width: 28}, {Title: "类型", Width: 8}, {Title: "大小", Width: 10}, {Title: "修改时间", Width: 18}}),
		providers:    newTUITable([]table.Column{{Title: "名称", Width: 24}, {Title: "格式", Width: 18}, {Title: "模型", Width: 8}, {Title: "API URL", Width: 42}}),
		sessions:     newTUITable([]table.Column{{Title: "ID", Width: 36}, {Title: "名称", Width: 32}, {Title: "临时", Width: 6}}),
		memories:     newTUITable([]table.Column{{Title: "ID", Width: 36}, {Title: "状态", Width: 8}, {Title: "内容", Width: 54}}),
		sqlTables:    newTUITable([]table.Column{{Title: "表", Width: 30}, {Title: "类型", Width: 8}, {Title: "字段", Width: 8}}),
		sqlRows:      newTUITable([]table.Column{{Title: "结果", Width: 90}}),
		captures:     newTUITable([]table.Column{{Title: "ID", Width: 36}, {Title: "模型", Width: 28}, {Title: "消息", Width: 8}, {Title: "时间", Width: 24}}),
		preview:      preview,
		currentPath:  ".",
		sqlDatabase:  "chat",
		messageStyle: tuiHelpStyle,
	}
	model.refreshStatus()
	return model
}

func newTUITable(columns []table.Column) table.Model {
	t := table.New(
		table.WithColumns(columns),
		table.WithRows([]table.Row{}),
		table.WithFocused(true),
		table.WithHeight(14),
	)
	styles := table.DefaultStyles()
	styles.Header = styles.Header.Bold(true).Foreground(lipgloss.Color("75"))
	styles.Selected = styles.Selected.Foreground(lipgloss.Color("230")).Background(lipgloss.Color("62"))
	t.SetStyles(styles)
	return t
}

func (m tuiModel) Init() tea.Cmd {
	return tea.Batch(m.spinner.Tick, tuiTick())
}

func (m tuiModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		m.layout(msg.Width, msg.Height)
	case tuiTickMsg:
		m.refreshStatus()
		cmds = append(cmds, tuiTick())
	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		cmds = append(cmds, cmd)
	case tuiCommandResultMsg:
		m.isLoading = false
		m.applyCommandResult(msg)
	case tea.KeyMsg:
		key := msg.String()
		appendAction := func(cmd tea.Cmd) {
			if cmd == nil {
				return
			}
			m.isLoading = true
			cmds = append(cmds, cmd)
		}
		switch key {
		case "ctrl+c", "esc":
			return m, tea.Quit
		case "tab", "right":
			m.nextView()
		case "shift+tab", "left":
			m.previousView()
		case "r":
			appendAction(m.refreshActiveView())
		case "enter":
			appendAction(m.enterSelected())
		case "p":
			if m.active == tuiFiles {
				appendAction(m.promptFilesPath())
			}
		case "b":
			if m.active == tuiFiles {
				m.currentPath = parentDevicePath(m.currentPath)
				appendAction(m.loadFiles(m.currentPath))
			}
		case "d":
			appendAction(m.downloadSelectedFile())
		case "x":
			appendAction(m.deleteSelected())
		case "n":
			appendAction(m.createSelectedKind())
		case "a":
			if m.active == tuiProviders {
				appendAction(m.addProvider())
			}
		case "m":
			if m.active == tuiProviders {
				appendAction(m.addProviderModel())
			}
		case "e":
			if m.active == tuiMemories {
				appendAction(m.editSelectedMemory())
			}
		case "1", "2", "3":
			if m.active == tuiSQLite {
				m.setSQLDatabase(key)
				appendAction(m.loadSQLiteTables())
			}
		case "q":
			if m.active == tuiSQLite {
				appendAction(m.promptSQLiteQuery(false))
			}
		case "w":
			if m.active == tuiSQLite {
				appendAction(m.promptSQLiteQuery(true))
			}
		case "s":
			if m.active == tuiCaptures {
				appendAction(m.resolveCapture(true))
			}
		case "i":
			if m.active == tuiCaptures {
				appendAction(m.resolveCapture(false))
			}
		}
	}

	var cmd tea.Cmd
	switch m.active {
	case tuiDashboard:
		m.nav, cmd = m.nav.Update(msg)
	case tuiFiles:
		m.filesTable, cmd = m.filesTable.Update(msg)
	case tuiProviders:
		m.providers, cmd = m.providers.Update(msg)
	case tuiSessions:
		m.sessions, cmd = m.sessions.Update(msg)
	case tuiMemories:
		m.memories, cmd = m.memories.Update(msg)
	case tuiSQLite:
		if len(m.sqlRows.Rows()) > 0 {
			m.sqlRows, cmd = m.sqlRows.Update(msg)
		} else {
			m.sqlTables, cmd = m.sqlTables.Update(msg)
		}
	case tuiCaptures:
		m.captures, cmd = m.captures.Update(msg)
	}
	cmds = append(cmds, cmd)
	return m, tea.Batch(cmds...)
}

func (m tuiModel) View() string {
	header := tuiTitleStyle.Render("ETOS LLM Studio 本地调试 TUI")
	if m.isLoading {
		header += " " + m.spinner.View()
	}

	status := m.renderStatusLine()
	content := m.renderActiveView()
	help := tuiHelpStyle.Render(m.renderHelp())
	message := ""
	if m.message != "" {
		message = "\n" + m.messageStyle.Render(m.message)
	}

	left := tuiBoxStyle.Width(30).Render(m.nav.View())
	rightWidth := maxInt(56, m.width-36)
	right := tuiBoxStyle.Width(rightWidth).Render(content + "\n\n" + help + message)

	return lipgloss.JoinVertical(
		lipgloss.Left,
		header,
		status,
		lipgloss.JoinHorizontal(lipgloss.Top, left, " ", right),
	)
}

func (m *tuiModel) layout(width, height int) {
	navHeight := maxInt(12, height-8)
	m.nav.SetSize(30, navHeight)
	tableHeight := maxInt(8, height-14)
	for _, t := range []*table.Model{&m.filesTable, &m.providers, &m.sessions, &m.memories, &m.sqlTables, &m.sqlRows, &m.captures} {
		t.SetHeight(tableHeight)
	}
	previewWidth := maxInt(50, width-42)
	m.preview.SetWidth(previewWidth)
	m.preview.SetHeight(maxInt(8, height-20))
}

func (m *tuiModel) refreshStatus() {
	connected, mode := m.server.getConnectionStatus()
	m.server.mu.RLock()
	m.status = tuiStatus{
		connected:       connected,
		mode:            mode,
		deviceName:      m.server.deviceName,
		queueSize:       len(m.server.commandQueue),
		pendingRequests: len(m.server.pendingResponses),
	}
	m.server.mu.RUnlock()
}

func (m tuiModel) renderStatusLine() string {
	dot := tuiErrStyle.Render("●")
	if m.status.connected {
		dot = tuiOKStyle.Render("●")
	}
	return fmt.Sprintf(
		"%s %s | %s | WS %s:%d | HTTP/Web %s:%d | Proxy %s:%d",
		dot,
		m.status.mode,
		m.status.deviceName,
		m.localIP,
		m.server.wsPort,
		m.localIP,
		m.server.httpPort,
		m.localIP,
		m.server.proxyPort,
	)
}

func (m tuiModel) renderActiveView() string {
	switch m.active {
	case tuiDashboard:
		return m.renderDashboard()
	case tuiFiles:
		return fmt.Sprintf("路径: %s\n\n%s\n\n%s", m.currentPath, m.filesTable.View(), m.preview.Value())
	case tuiProviders:
		return "提供商\n\n" + m.providers.View() + "\n\n" + m.preview.Value()
	case tuiSessions:
		return "会话\n\n" + m.sessions.View() + "\n\n" + m.preview.Value()
	case tuiMemories:
		return "记忆\n\n" + m.memories.View() + "\n\n" + m.preview.Value()
	case tuiSQLite:
		return fmt.Sprintf("数据库: %s  [1 chat / 2 config / 3 memory]\n\n表结构\n%s\n\n查询结果\n%s\n\n%s", m.sqlDatabase, m.sqlTables.View(), m.sqlRows.View(), m.preview.Value())
	case tuiCaptures:
		return "OpenAI 捕获队列\n\n" + m.captures.View() + "\n\n" + m.preview.Value()
	default:
		return ""
	}
}

func (m tuiModel) renderDashboard() string {
	lines := []string{
		"连接",
		fmt.Sprintf("  设备: %s", m.status.deviceName),
		fmt.Sprintf("  模式: %s", m.status.mode),
		fmt.Sprintf("  待发命令: %d", m.status.queueSize),
		fmt.Sprintf("  等待响应: %d", m.status.pendingRequests),
		"",
		"地址",
		fmt.Sprintf("  WebSocket: ws://%s:%d", m.localIP, m.server.wsPort),
		fmt.Sprintf("  HTTP/Web: http://%s:%d", m.localIP, m.server.httpPort),
		fmt.Sprintf("  OpenAI 代理: http://%s:%d/v1/chat/completions", m.localIP, m.server.proxyPort),
		"",
		"快速开始",
		"  在设备端填入电脑 IP 后连接；连接成功后用 Tab 切换模块。",
		"  WebUI 与 TUI 共用同一组 /api/* 接口。",
	}
	return strings.Join(lines, "\n")
}

func (m tuiModel) renderHelp() string {
	common := "Tab 切换 | r 刷新 | ↑↓ 选择 | Esc 退出"
	switch m.active {
	case tuiFiles:
		return common + " | p 路径 | Enter 打开/预览 | b 上级 | d 下载 | x 删除 | n 新建目录"
	case tuiProviders:
		return common + " | Enter 详情 | a 新增 Provider | m 给选中 Provider 加模型"
	case tuiSessions:
		return common + " | Enter 懒加载详情 | n 新建会话 | x 删除"
	case tuiMemories:
		return common + " | Enter 详情 | e 编辑 | x 归档/取消归档 | n 重嵌入全部"
	case tuiSQLite:
		return common + " | 1/2/3 选库 | q 查询 | w 写入"
	case tuiCaptures:
		return common + " | s 保存选中 | i 忽略选中"
	default:
		return common
	}
}

func (m *tuiModel) nextView() {
	m.active = tuiView((int(m.active) + 1) % 7)
	m.nav.Select(int(m.active))
}

func (m *tuiModel) previousView() {
	next := int(m.active) - 1
	if next < 0 {
		next = 6
	}
	m.active = tuiView(next)
	m.nav.Select(next)
}

func (m *tuiModel) setMessage(text string, style lipgloss.Style) {
	m.message = text
	m.messageStyle = style
}

func (m tuiModel) refreshActiveView() tea.Cmd {
	switch m.active {
	case tuiFiles:
		return m.loadFiles(m.currentPath)
	case tuiProviders:
		return m.loadProviders()
	case tuiSessions:
		return m.loadSessions()
	case tuiMemories:
		return m.loadMemories()
	case tuiSQLite:
		return m.loadSQLiteTables()
	case tuiCaptures:
		return m.loadCaptures()
	default:
		return nil
	}
}

func (m tuiModel) enterSelected() tea.Cmd {
	switch m.active {
	case tuiFiles:
		row := m.filesTable.SelectedRow()
		if len(row) == 0 {
			return nil
		}
		name := row[0]
		path := joinDevicePath(m.currentPath, name)
		if row[1] == "目录" {
			return m.loadFiles(path)
		}
		return m.readFile(path)
	case tuiProviders:
		return m.showSelectedProvider()
	case tuiSessions:
		return m.loadSelectedSession()
	case tuiMemories:
		return m.showSelectedMemory()
	case tuiSQLite:
		row := m.sqlTables.SelectedRow()
		if len(row) > 0 {
			sql := fmt.Sprintf("SELECT * FROM %s", quoteSQLiteIdentifierForTUI(row[0]))
			return m.runSQLiteQuery(sql, false)
		}
	case tuiCaptures:
		return m.showSelectedCapture()
	}
	return nil
}

func (m tuiModel) remoteCommand(op string, payload map[string]any, timeout time.Duration) tea.Cmd {
	return func() tea.Msg {
		response, err := m.server.sendCommandWithResponse(payload, timeout)
		return tuiCommandResultMsg{op: op, response: response, err: err}
	}
}

func (m tuiModel) loadFiles(path string) tea.Cmd {
	payload := map[string]any{"command": "list", "path": path}
	return m.markLoading(m.remoteCommand("files:list:"+path, payload, 20*time.Second))
}

func (m tuiModel) readFile(path string) tea.Cmd {
	payload := map[string]any{"command": "download", "path": path}
	return m.markLoading(m.remoteCommand("files:read:"+path, payload, 30*time.Second))
}

func (m tuiModel) downloadSelectedFile() tea.Cmd {
	if m.active != tuiFiles {
		return nil
	}
	row := m.filesTable.SelectedRow()
	if len(row) == 0 || row[1] == "目录" {
		return nil
	}
	return m.readFile(joinDevicePath(m.currentPath, row[0]))
}

func (m tuiModel) promptFilesPath() tea.Cmd {
	return func() tea.Msg {
		path := m.currentPath
		form := huh.NewForm(huh.NewGroup(
			huh.NewInput().Title("设备路径").Value(&path),
		))
		if err := form.Run(); err != nil {
			return tuiCommandResultMsg{op: "noop", err: err}
		}
		path = strings.TrimSpace(path)
		if path == "" {
			path = "."
		}
		response, err := m.server.sendCommandWithResponse(map[string]any{"command": "list", "path": path}, 20*time.Second)
		return tuiCommandResultMsg{op: "files:list:" + path, response: response, err: err}
	}
}

func (m tuiModel) loadProviders() tea.Cmd {
	return m.markLoading(m.remoteCommand("providers:list", map[string]any{"command": "providers_list"}, 25*time.Second))
}

func (m tuiModel) addProvider() tea.Cmd {
	return func() tea.Msg {
		name := ""
		baseURL := ""
		apiKey := ""
		apiFormat := "openai-compatible"
		form := huh.NewForm(huh.NewGroup(
			huh.NewInput().Title("名称").Value(&name),
			huh.NewInput().Title("API URL").Value(&baseURL),
			huh.NewInput().Title("API Key").EchoMode(huh.EchoModePassword).Value(&apiKey),
			huh.NewInput().Title("API 格式").Value(&apiFormat),
		))
		if err := form.Run(); err != nil {
			return tuiCommandResultMsg{op: "noop", err: err}
		}
		providers, err := m.fetchProviderList()
		if err != nil {
			return tuiCommandResultMsg{op: "providers:add", err: err}
		}
		providers = append(providers, map[string]any{
			"id":        newUUIDLikeString(),
			"name":      strings.TrimSpace(name),
			"baseURL":   strings.TrimSpace(baseURL),
			"apiKeys":   []any{apiKey},
			"apiFormat": strings.TrimSpace(apiFormat),
			"models":    []any{},
		})
		response, err := m.server.sendCommandWithResponse(map[string]any{"command": "providers_save", "providers": providers}, 45*time.Second)
		return tuiCommandResultMsg{op: "providers:save", response: response, err: err}
	}
}

func (m tuiModel) addProviderModel() tea.Cmd {
	row := m.providers.SelectedRow()
	if len(row) == 0 {
		return nil
	}
	providerID := row[0]
	return func() tea.Msg {
		modelName := ""
		displayName := ""
		form := huh.NewForm(huh.NewGroup(
			huh.NewInput().Title("模型 ID").Value(&modelName),
			huh.NewInput().Title("显示名称").Value(&displayName),
		))
		if err := form.Run(); err != nil {
			return tuiCommandResultMsg{op: "noop", err: err}
		}
		providers, err := m.fetchProviderList()
		if err != nil {
			return tuiCommandResultMsg{op: "providers:model", err: err}
		}
		for _, provider := range providers {
			if asString(provider["id"]) != providerID {
				continue
			}
			model := map[string]any{
				"id":          newUUIDLikeString(),
				"modelName":   strings.TrimSpace(modelName),
				"displayName": strings.TrimSpace(displayName),
				"isActivated": true,
			}
			if model["displayName"] == "" {
				model["displayName"] = model["modelName"]
			}
			models := asAnySlice(provider["models"])
			models = append(models, model)
			provider["models"] = models
			break
		}
		response, err := m.server.sendCommandWithResponse(map[string]any{"command": "providers_save", "providers": providers}, 45*time.Second)
		return tuiCommandResultMsg{op: "providers:save", response: response, err: err}
	}
}

func (m tuiModel) fetchProviderList() ([]map[string]any, error) {
	response, err := m.server.sendCommandWithResponse(map[string]any{"command": "providers_list"}, 25*time.Second)
	if err != nil {
		return nil, err
	}
	return asMapSlice(response["providers"]), nil
}

func (m tuiModel) showSelectedProvider() tea.Cmd {
	row := m.providers.SelectedRow()
	if len(row) == 0 {
		return nil
	}
	id := row[0]
	return func() tea.Msg {
		providers, err := m.fetchProviderList()
		if err != nil {
			return tuiCommandResultMsg{op: "providers:detail", err: err}
		}
		for _, provider := range providers {
			if asString(provider["id"]) == id {
				return tuiCommandResultMsg{op: "preview", response: map[string]any{"status": "ok", "preview": prettyJSON(provider)}}
			}
		}
		return tuiCommandResultMsg{op: "preview", err: fmt.Errorf("未找到提供商")}
	}
}

func (m tuiModel) loadSessions() tea.Cmd {
	return m.markLoading(m.remoteCommand("sessions:list", map[string]any{"command": "sessions_list"}, 25*time.Second))
}

func (m tuiModel) loadSelectedSession() tea.Cmd {
	row := m.sessions.SelectedRow()
	if len(row) == 0 {
		return nil
	}
	payload := map[string]any{"command": "session_get", "session_id": row[0]}
	return m.markLoading(m.remoteCommand("sessions:get", payload, 30*time.Second))
}

func (m tuiModel) loadMemories() tea.Cmd {
	return m.markLoading(m.remoteCommand("memories:list", map[string]any{"command": "memories_list"}, 30*time.Second))
}

func (m tuiModel) loadSQLiteTables() tea.Cmd {
	payload := map[string]any{"command": "list_sqlite_tables", "database": m.sqlDatabase}
	return m.markLoading(m.remoteCommand("sqlite:tables", payload, 30*time.Second))
}

func (m tuiModel) promptSQLiteQuery(mutating bool) tea.Cmd {
	return func() tea.Msg {
		sql := "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view')"
		if mutating {
			sql = "UPDATE table_name SET column_name = ? WHERE id = ?"
		}
		form := huh.NewForm(huh.NewGroup(
			huh.NewText().Title("SQL").Value(&sql),
		))
		if err := form.Run(); err != nil {
			return tuiCommandResultMsg{op: "noop", err: err}
		}
		op := "sqlite:query"
		command := "query_sqlite"
		if mutating {
			op = "sqlite:mutate"
			command = "mutate_sqlite"
		}
		response, err := m.server.sendCommandWithResponse(map[string]any{
			"command":             command,
			"database":            m.sqlDatabase,
			"sql":                 sql,
			"allow_without_where": false,
			"returning_max_rows":  50,
			"max_rows":            50,
			"parameters":          []any{},
		}, 60*time.Second)
		return tuiCommandResultMsg{op: op, response: response, err: err}
	}
}

func (m tuiModel) runSQLiteQuery(sql string, mutating bool) tea.Cmd {
	command := "query_sqlite"
	op := "sqlite:query"
	if mutating {
		command = "mutate_sqlite"
		op = "sqlite:mutate"
	}
	return m.markLoading(m.remoteCommand(op, map[string]any{
		"command":  command,
		"database": m.sqlDatabase,
		"sql":      sql,
		"max_rows": 50,
	}, 60*time.Second))
}

func (m tuiModel) loadCaptures() tea.Cmd {
	return m.markLoading(m.remoteCommand("captures:list", map[string]any{"command": "openai_queue_list"}, 20*time.Second))
}

func (m tuiModel) resolveCapture(save bool) tea.Cmd {
	row := m.captures.SelectedRow()
	if len(row) == 0 {
		return nil
	}
	payload := map[string]any{"command": "openai_queue_resolve", "id": row[0], "save": save}
	return m.markLoading(m.remoteCommand("captures:resolve", payload, 30*time.Second))
}

func (m tuiModel) showSelectedCapture() tea.Cmd {
	row := m.captures.SelectedRow()
	if len(row) == 0 {
		return nil
	}
	return func() tea.Msg {
		return tuiCommandResultMsg{op: "preview", response: map[string]any{"status": "ok", "preview": strings.Join(row, "\n")}}
	}
}

func (m tuiModel) deleteSelected() tea.Cmd {
	switch m.active {
	case tuiFiles:
		row := m.filesTable.SelectedRow()
		if len(row) == 0 {
			return nil
		}
		path := joinDevicePath(m.currentPath, row[0])
		return m.confirmAndRun("确认删除设备路径 "+path+"？", "files:delete", map[string]any{"command": "delete", "path": path}, 30*time.Second)
	case tuiSessions:
		row := m.sessions.SelectedRow()
		if len(row) == 0 {
			return nil
		}
		return m.confirmAndRun("确认删除会话 "+row[1]+"？", "sessions:delete", map[string]any{"command": "session_delete", "session_id": row[0]}, 30*time.Second)
	case tuiMemories:
		row := m.memories.SelectedRow()
		if len(row) == 0 {
			return nil
		}
		archive := row[1] != "归档"
		return m.markLoading(m.remoteCommand("memories:update", map[string]any{
			"command":     "memory_update",
			"memory_id":   row[0],
			"is_archived": archive,
		}, 45*time.Second))
	}
	return nil
}

func (m tuiModel) createSelectedKind() tea.Cmd {
	switch m.active {
	case tuiFiles:
		return func() tea.Msg {
			path := m.currentPath
			form := huh.NewForm(huh.NewGroup(huh.NewInput().Title("新目录路径").Value(&path)))
			if err := form.Run(); err != nil {
				return tuiCommandResultMsg{op: "noop", err: err}
			}
			response, err := m.server.sendCommandWithResponse(map[string]any{"command": "mkdir", "path": strings.TrimSpace(path)}, 30*time.Second)
			return tuiCommandResultMsg{op: "files:mkdir", response: response, err: err}
		}
	case tuiSessions:
		return func() tea.Msg {
			name := "新的对话"
			form := huh.NewForm(huh.NewGroup(huh.NewInput().Title("会话名称").Value(&name)))
			if err := form.Run(); err != nil {
				return tuiCommandResultMsg{op: "noop", err: err}
			}
			response, err := m.server.sendCommandWithResponse(map[string]any{"command": "session_create", "name": strings.TrimSpace(name)}, 30*time.Second)
			return tuiCommandResultMsg{op: "sessions:create", response: response, err: err}
		}
	case tuiMemories:
		return m.confirmAndRun("确认重嵌入全部记忆？", "memories:reembed", map[string]any{"command": "memories_reembed_all"}, 15*time.Minute)
	}
	return nil
}

func (m tuiModel) editSelectedMemory() tea.Cmd {
	row := m.memories.SelectedRow()
	if len(row) == 0 {
		return nil
	}
	memoryID := row[0]
	current := row[2]
	return func() tea.Msg {
		content := current
		form := huh.NewForm(huh.NewGroup(huh.NewText().Title("记忆内容").Value(&content)))
		if err := form.Run(); err != nil {
			return tuiCommandResultMsg{op: "noop", err: err}
		}
		response, err := m.server.sendCommandWithResponse(map[string]any{"command": "memory_update", "memory_id": memoryID, "content": content}, 45*time.Second)
		return tuiCommandResultMsg{op: "memories:update", response: response, err: err}
	}
}

func (m tuiModel) showSelectedMemory() tea.Cmd {
	row := m.memories.SelectedRow()
	if len(row) == 0 {
		return nil
	}
	return func() tea.Msg {
		return tuiCommandResultMsg{op: "preview", response: map[string]any{"status": "ok", "preview": fmt.Sprintf("%s\n\n%s", row[1], row[2])}}
	}
}

func (m tuiModel) confirmAndRun(title, op string, payload map[string]any, timeout time.Duration) tea.Cmd {
	return func() tea.Msg {
		ok := false
		if err := huh.NewConfirm().Title(title).Value(&ok).Run(); err != nil {
			return tuiCommandResultMsg{op: "noop", err: err}
		}
		if !ok {
			return tuiCommandResultMsg{op: "noop", response: map[string]any{"status": "ok", "message": "已取消"}}
		}
		response, err := m.server.sendCommandWithResponse(payload, timeout)
		return tuiCommandResultMsg{op: op, response: response, err: err}
	}
}

func (m tuiModel) markLoading(cmd tea.Cmd) tea.Cmd {
	if cmd == nil {
		return nil
	}
	return func() tea.Msg {
		return cmd()
	}
}

func (m *tuiModel) setSQLDatabase(key string) {
	switch key {
	case "1":
		m.sqlDatabase = "chat"
	case "2":
		m.sqlDatabase = "config"
	case "3":
		m.sqlDatabase = "memory"
	}
}

func (m *tuiModel) applyCommandResult(msg tuiCommandResultMsg) {
	if msg.err != nil {
		m.setMessage(msg.err.Error(), tuiErrStyle)
		return
	}
	if msg.response == nil {
		return
	}
	if asString(msg.response["status"]) == "error" {
		m.setMessage(asString(msg.response["message"]), tuiErrStyle)
		return
	}

	switch {
	case strings.HasPrefix(msg.op, "files:list:"):
		m.currentPath = strings.TrimPrefix(msg.op, "files:list:")
		m.applyFiles(msg.response)
	case strings.HasPrefix(msg.op, "files:read:"):
		m.applyReadFile(strings.TrimPrefix(msg.op, "files:read:"), msg.response)
	case msg.op == "providers:list":
		m.applyProviders(msg.response)
	case msg.op == "providers:save":
		m.setMessage("提供商已保存", tuiOKStyle)
	case msg.op == "sessions:list":
		m.applySessions(msg.response)
	case msg.op == "sessions:get":
		m.preview.SetValue(prettyJSON(msg.response))
	case msg.op == "memories:list":
		m.applyMemories(msg.response)
	case msg.op == "sqlite:tables":
		m.applySQLiteTables(msg.response)
	case msg.op == "sqlite:query":
		m.applySQLiteRows(msg.response)
	case msg.op == "sqlite:mutate":
		m.preview.SetValue(prettyJSON(msg.response))
		m.setMessage("SQL 写入已执行", tuiOKStyle)
	case msg.op == "captures:list":
		m.applyCaptures(msg.response)
	case msg.op == "preview":
		m.preview.SetValue(asString(msg.response["preview"]))
	default:
		if message := asString(msg.response["message"]); message != "" {
			m.setMessage(message, tuiOKStyle)
		}
	}
}

func tuiTick() tea.Cmd {
	return tea.Tick(250*time.Millisecond, func(t time.Time) tea.Msg {
		return tuiTickMsg(t)
	})
}

func runTUI(ctxDone <-chan struct{}, server *DebugServer, localIP string) error {
	model := newTUIModel(server, localIP)
	program := tea.NewProgram(model, tea.WithAltScreen())
	done := make(chan error, 1)
	go func() {
		_, err := program.Run()
		done <- err
	}()
	select {
	case <-ctxDone:
		program.Quit()
		return <-done
	case err := <-done:
		return err
	}
}
