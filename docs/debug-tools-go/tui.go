package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/table"
	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"
)

type tuiView int

const (
	tuiDashboard tuiView = iota
	tuiFiles
	tuiProviders
	tuiSettings
	tuiMCP
	tuiSessions
	tuiMemories
	tuiSQLite
)

const tuiViewCount = 8

const (
	tuiDefaultNavWidth      = 30
	tuiMinNavWidth          = 22
	tuiMinContentWidth      = 24
	tuiPanelHorizontalFrame = 4
	tuiPanelGapWidth        = 1
)

type tuiFocus int

const (
	tuiFocusNav tuiFocus = iota
	tuiFocusContent
	tuiFocusDetail
)

type tuiSessionMode int

const (
	tuiSessionModeList tuiSessionMode = iota
	tuiSessionModeMessages
	tuiSessionModeMessageDetail
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

type tuiExternalQuitMsg struct{}

type tuiCommandResultMsg struct {
	op          string
	response    map[string]any
	err         error
	clearScreen bool
}

type tuiInlineForm struct {
	title  string
	form   *huh.Form
	submit func(*tuiModel) tea.Cmd
}

type tuiStatus struct {
	connected       bool
	mode            string
	deviceName      string
	queueSize       int
	pendingRequests int
	serviceStarted  bool
	serviceError    string
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
	settings   table.Model
	mcpServers table.Model
	sessions   table.Model
	memories   table.Model
	sqlTables  table.Model
	sqlRows    table.Model
	preview    textarea.Model
	content    viewport.Model

	status       tuiStatus
	currentPath  string
	sqlDatabase  string
	focus        tuiFocus
	sessionMode  tuiSessionMode
	isLoading    bool
	message      string
	messageStyle lipgloss.Style
	activeForm   *tuiInlineForm

	fileItems              []map[string]any
	providerRows           []map[string]any
	settingRows            []map[string]any
	mcpRows                []map[string]any
	sessionRows            []map[string]any
	activeSession          map[string]any
	sessionAllMessages     []map[string]any
	sessionMessages        []map[string]any
	selectedSessionMessage int
	selectedSessionDetail  int
	memoryRows             []map[string]any
}

var (
	tuiTitleStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("75"))
	tuiBoxStyle   = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("240")).
			Padding(0, 1)
	tuiFocusBoxStyle = tuiBoxStyle.Copy().BorderForeground(lipgloss.Color("75"))
	tuiHelpStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	tuiDetailStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("219")).Bold(true)
	tuiOKStyle       = lipgloss.NewStyle().Foreground(lipgloss.Color("42"))
	tuiWarnStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("214"))
	tuiErrStyle      = lipgloss.NewStyle().Foreground(lipgloss.Color("203"))
)

func newTUIModel(server *DebugServer, localIP string) tuiModel {
	navItems := []list.Item{
		navItem{"总览", "连接状态、端口与操作提示", tuiDashboard},
		navItem{"文件", "浏览、下载、删除、创建目录", tuiFiles},
		navItem{"提供商", "查看提供商，新增 API 与模型", tuiProviders},
		navItem{"设置", "查看与修改 app_config 配置", tuiSettings},
		navItem{"MCP", "管理服务器、Key 与工具策略", tuiMCP},
		navItem{"会话", "懒加载会话详情，创建与删除", tuiSessions},
		navItem{"记忆", "编辑、归档与重嵌入", tuiMemories},
		navItem{"SQLite", "表结构、查询与写入 SQL", tuiSQLite},
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

	content := viewport.New(80, 18)
	content.MouseWheelEnabled = true
	content.MouseWheelDelta = 4

	model := tuiModel{
		server:       server,
		localIP:      localIP,
		nav:          nav,
		spinner:      spin,
		filesTable:   newTUITable([]table.Column{{Title: "名称", Width: 28}, {Title: "类型", Width: 8}, {Title: "大小", Width: 10}, {Title: "修改时间", Width: 18}}),
		providers:    newTUITable([]table.Column{{Title: "名称", Width: 24}, {Title: "格式", Width: 18}, {Title: "模型", Width: 8}, {Title: "API URL", Width: 42}}),
		settings:     newTUITable([]table.Column{{Title: "Key", Width: 38}, {Title: "分组", Width: 14}, {Title: "类型", Width: 8}, {Title: "同步", Width: 6}, {Title: "值", Width: 42}}),
		mcpServers:   newTUITable([]table.Column{{Title: "ID", Width: 36}, {Title: "名称", Width: 24}, {Title: "传输", Width: 8}, {Title: "聊天", Width: 6}, {Title: "工具", Width: 6}, {Title: "Endpoint", Width: 42}}),
		sessions:     newTUITable([]table.Column{{Title: "ID", Width: 36}, {Title: "名称", Width: 42}, {Title: "信息", Width: 28}}),
		memories:     newTUITable([]table.Column{{Title: "ID", Width: 36}, {Title: "状态", Width: 8}, {Title: "内容", Width: 54}}),
		sqlTables:    newTUITable([]table.Column{{Title: "表", Width: 30}, {Title: "类型", Width: 8}, {Title: "字段", Width: 8}}),
		sqlRows:      newTUITable([]table.Column{{Title: "结果", Width: 90}}),
		preview:      preview,
		content:      content,
		currentPath:  ".",
		sqlDatabase:  "chat",
		focus:        tuiFocusNav,
		messageStyle: tuiHelpStyle,
	}
	model.refreshStatus()
	model.syncFocusedComponent()
	model.syncContentViewport()
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
		m.syncContentViewport()
		m.resizeActiveForm()
		if m.activeForm != nil {
			cmds = append(cmds, m.updateActiveForm(msg)...)
		}
	case tuiTickMsg:
		m.refreshStatus()
		if m.active == tuiDashboard {
			m.syncContentViewport()
		}
		cmds = append(cmds, tuiTick())
	case tuiExternalQuitMsg:
		return m, tea.Quit
	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		cmds = append(cmds, cmd)
	case tuiCommandResultMsg:
		m.isLoading = false
		m.applyCommandResult(msg)
		m.syncContentViewport()
		if msg.clearScreen {
			cmds = append(cmds, tea.ClearScreen)
		}
	case tea.KeyMsg:
		key := msg.String()
		if key == "ctrl+c" {
			return m, tea.Quit
		}
		if m.activeForm != nil {
			cmds = append(cmds, m.updateActiveForm(msg)...)
			return m, tea.Batch(cmds...)
		}

		appendAction := func(cmd tea.Cmd) {
			if cmd == nil {
				return
			}
			m.isLoading = m.activeForm == nil
			cmds = append(cmds, cmd)
		}

		switch key {
		case "esc":
			if m.focus == tuiFocusDetail {
				m.focus = tuiFocusContent
				m.syncFocusedComponent()
				m.syncContentViewport()
				return m, tea.Batch(cmds...)
			}
			if m.active == tuiSessions && m.focus == tuiFocusContent && m.handleSessionBack() {
				m.syncFocusedComponent()
				m.syncContentViewport()
				return m, tea.Batch(cmds...)
			}
			if m.focus == tuiFocusContent {
				m.focus = tuiFocusNav
				m.syncFocusedComponent()
				m.syncContentViewport()
			}
			return m, tea.Batch(cmds...)
		case "left":
			m.focus = tuiFocusNav
			m.syncFocusedComponent()
			m.syncContentViewport()
			return m, tea.Batch(cmds...)
		case "right":
			m.focus = tuiFocusContent
			m.syncFocusedComponent()
			m.syncContentViewport()
			return m, tea.Batch(cmds...)
		case "tab":
			m.nextView()
			m.focus = tuiFocusContent
			m.syncFocusedComponent()
			m.syncContentViewport()
			appendAction(m.refreshActiveViewIfConnected())
			return m, tea.Batch(cmds...)
		case "shift+tab":
			m.previousView()
			m.focus = tuiFocusContent
			m.syncFocusedComponent()
			m.syncContentViewport()
			appendAction(m.refreshActiveViewIfConnected())
			return m, tea.Batch(cmds...)
		}

		if m.focus == tuiFocusNav {
			previous := m.active
			var cmd tea.Cmd
			m.nav, cmd = m.nav.Update(msg)
			cmds = append(cmds, cmd)
			m.syncActiveViewFromNav()
			if previous != m.active {
				m.syncFocusedComponent()
				m.resetContentViewport()
				appendAction(m.refreshActiveViewIfConnected())
			}
			if key == "enter" {
				m.focus = tuiFocusContent
				m.syncFocusedComponent()
			}
		} else {
			appendAction(m.handleContentKey(key))
			var cmd tea.Cmd
			m, cmd = m.updateActiveContentComponent(msg)
			cmds = append(cmds, cmd)
			m.syncContentViewport()
		}
	case tea.MouseMsg:
		if m.activeForm != nil {
			cmds = append(cmds, m.updateActiveForm(msg)...)
			return m, tea.Batch(cmds...)
		}
		if cmd := m.handleMouse(msg); cmd != nil {
			cmds = append(cmds, cmd)
		}
	default:
		if m.activeForm != nil {
			cmds = append(cmds, m.updateActiveForm(msg)...)
		}
	}

	return m, tea.Batch(cmds...)
}

func (m *tuiModel) updateActiveForm(msg tea.Msg) []tea.Cmd {
	if m.activeForm == nil {
		return nil
	}
	var cmds []tea.Cmd
	updated, cmd := m.activeForm.form.Update(msg)
	if cmd != nil {
		cmds = append(cmds, cmd)
	}
	if form, ok := updated.(*huh.Form); ok {
		m.activeForm.form = form
	}

	switch m.activeForm.form.State {
	case huh.StateCompleted:
		activeForm := m.activeForm
		m.activeForm = nil
		m.isLoading = false
		if activeForm.submit != nil {
			if submitCmd := activeForm.submit(m); submitCmd != nil {
				m.isLoading = m.activeForm == nil
				cmds = append(cmds, submitCmd)
			}
		}
		m.syncFocusedComponent()
		m.syncContentViewport()
	case huh.StateAborted:
		m.activeForm = nil
		m.isLoading = false
		m.setMessage("已取消输入", tuiHelpStyle)
		m.syncFocusedComponent()
		m.syncContentViewport()
	}
	return cmds
}

func (m tuiModel) View() string {
	header := tuiTitleStyle.Render("ETOS LLM Studio 本地调试 TUI")
	if m.isLoading && m.activeForm == nil {
		header += " " + m.spinner.View()
	}

	status := m.renderStatusLine()
	help := tuiHelpStyle.Render(m.renderHelp())
	message := ""
	if m.message != "" {
		message = "\n" + m.messageStyle.Render(m.message)
	}

	boxHeight := m.boxHeight()
	leftStyle := tuiBoxStyle
	rightStyle := tuiBoxStyle
	if m.focus == tuiFocusNav {
		leftStyle = tuiFocusBoxStyle
	} else {
		rightStyle = tuiFocusBoxStyle
	}
	leftWidth := m.navContentWidth()
	left := leftStyle.Width(leftWidth).Height(boxHeight).Render(m.nav.View())
	rightWidth := m.rightContentWidth()
	right := rightStyle.Width(rightWidth).Height(boxHeight).Render(m.renderRightPanel(help, message))

	return lipgloss.JoinVertical(
		lipgloss.Left,
		header,
		status,
		lipgloss.JoinHorizontal(lipgloss.Top, left, " ", right),
	)
}

func (m tuiModel) renderRightPanel(help, message string) string {
	if m.activeForm == nil {
		return m.content.View() + "\n\n" + help + message
	}

	contextHeight := m.inlineFormContextHeight()
	context := clipRenderedLines(m.content.View(), contextHeight)
	formHelp := tuiHelpStyle.Render("表单 | ↑↓/Tab 切换 | Enter 确认 | Esc 取消 | Ctrl+C 退出")
	title := tuiDetailStyle.Render("▶ " + m.activeForm.title)
	separator := tuiHelpStyle.Render(strings.Repeat("─", maxInt(8, minInt(m.rightContentWidth(), 80))))

	return strings.Join([]string{
		context,
		separator,
		title,
		m.activeForm.form.View(),
		"",
		formHelp,
		message,
	}, "\n")
}

func (m *tuiModel) layout(width, height int) {
	boxHeight := m.boxHeight()
	navWidth := m.navContentWidth()
	navHeight := maxInt(8, boxHeight-2)
	m.nav.SetSize(navWidth, navHeight)
	contentHeight := maxInt(5, boxHeight-8)
	contentWidth := m.rightContentWidth()
	m.content.Width = contentWidth
	m.content.Height = contentHeight
	tableHeight := tuiPrimaryTableHeight(contentHeight)
	for _, t := range []*table.Model{&m.filesTable, &m.providers, &m.settings, &m.mcpServers, &m.sessions, &m.memories} {
		t.SetHeight(tableHeight)
	}
	sqlTablesHeight := tuiSQLTablesHeight(contentHeight)
	sqlRowsHeight := tuiSQLRowsHeight(contentHeight)
	m.sqlTables.SetHeight(sqlTablesHeight)
	m.sqlRows.SetHeight(sqlRowsHeight)
	previewWidth := maxInt(38, contentWidth-2)
	m.preview.SetWidth(previewWidth)
	m.preview.SetHeight(tuiPreviewHeightForLayout(contentHeight, m.active, tableHeight, sqlTablesHeight, sqlRowsHeight))
	m.resizeActiveForm()
}

func tuiPrimaryTableHeight(contentHeight int) int {
	maxTableHeight := maxInt(5, contentHeight-9)
	return maxInt(5, minInt(maxInt(12, contentHeight/2), maxTableHeight))
}

func tuiSQLTablesHeight(contentHeight int) int {
	return maxInt(4, minInt(10, contentHeight/4))
}

func tuiSQLRowsHeight(contentHeight int) int {
	return maxInt(5, minInt(maxInt(8, contentHeight/3), maxInt(5, contentHeight-tuiSQLTablesHeight(contentHeight)-12)))
}

func tuiPreviewHeightForLayout(contentHeight int, active tuiView, tableHeight, sqlTablesHeight, sqlRowsHeight int) int {
	if active == tuiSQLite {
		return maxInt(4, contentHeight-sqlTablesHeight-sqlRowsHeight-8)
	}
	return maxInt(4, contentHeight-tableHeight-5)
}

func (m tuiModel) boxHeight() int {
	if m.height <= 0 {
		return 22
	}
	return maxInt(10, m.height-5)
}

func (m tuiModel) navContentWidth() int {
	if m.width <= 0 {
		return tuiDefaultNavWidth
	}
	if m.width >= 80 {
		return tuiDefaultNavWidth
	}
	available := m.width / 3
	return minInt(tuiDefaultNavWidth, maxInt(tuiMinNavWidth, available))
}

func (m tuiModel) rightContentWidth() int {
	if m.width <= 0 {
		return 80
	}
	usedByNav := m.navContentWidth() + tuiPanelHorizontalFrame
	usedByRightFrame := tuiPanelHorizontalFrame
	available := m.width - usedByNav - tuiPanelGapWidth - usedByRightFrame
	return maxInt(tuiMinContentWidth, available)
}

func (m tuiModel) inlineFormContextHeight() int {
	boxHeight := m.boxHeight()
	if boxHeight < 18 {
		return maxInt(2, boxHeight/4)
	}
	return minInt(12, maxInt(5, boxHeight/4))
}

func (m tuiModel) inlineFormHeight() int {
	return maxInt(6, m.boxHeight()-m.inlineFormContextHeight()-7)
}

func (m *tuiModel) resizeActiveForm() {
	if m.activeForm == nil || m.activeForm.form == nil {
		return
	}
	m.activeForm.form.
		WithWidth(maxInt(28, m.rightContentWidth()-2)).
		WithHeight(m.inlineFormHeight())
}

func (m *tuiModel) beginInlineForm(title string, form *huh.Form, submit func(*tuiModel) tea.Cmd) tea.Cmd {
	m.activeForm = &tuiInlineForm{
		title:  title,
		form:   form,
		submit: submit,
	}
	m.isLoading = false
	m.resizeActiveForm()
	return m.activeForm.form.Init()
}

func tuiMessageCommand(msg tea.Msg) tea.Cmd {
	return func() tea.Msg {
		return msg
	}
}

func clipRenderedLines(value string, maxLines int) string {
	if maxLines <= 0 {
		return ""
	}
	lines := strings.Split(value, "\n")
	if len(lines) <= maxLines {
		return value
	}
	clipped := append([]string(nil), lines[:maxLines]...)
	clipped = append(clipped, tuiHelpStyle.Render("…"))
	return strings.Join(clipped, "\n")
}

func (m *tuiModel) refreshStatus() {
	connected, mode := m.server.getConnectionStatus()
	serviceStarted, serviceError := m.server.getServiceStatus()
	m.server.mu.RLock()
	m.status = tuiStatus{
		connected:       connected,
		mode:            mode,
		deviceName:      m.server.deviceName,
		queueSize:       len(m.server.commandQueue),
		pendingRequests: len(m.server.pendingResponses),
		serviceStarted:  serviceStarted,
		serviceError:    serviceError,
	}
	m.server.mu.RUnlock()
}

func (m tuiModel) renderStatusLine() string {
	if m.status.serviceError != "" {
		return fmt.Sprintf(
			"%s 服务启动失败 | %s:%d | %s",
			tuiErrStyle.Render("●"),
			m.localIP,
			m.server.port,
			m.status.serviceError,
		)
	}

	dot := tuiErrStyle.Render("●")
	if m.status.connected {
		dot = tuiOKStyle.Render("●")
	}
	return fmt.Sprintf(
		"%s %s | %s | %s:%d | WS %s | OpenAI /v1",
		dot,
		m.status.mode,
		m.status.deviceName,
		m.localIP,
		m.server.port,
		wsPath,
	)
}

func (m tuiModel) renderActiveView() string {
	switch m.active {
	case tuiDashboard:
		return m.renderDashboard()
	case tuiFiles:
		return fmt.Sprintf("路径: %s\n\n%s\n\n%s", m.currentPath, m.filesTable.View(), m.renderPreviewBlock())
	case tuiProviders:
		return "提供商\n\n" + m.providers.View() + "\n\n" + m.renderPreviewBlock()
	case tuiSettings:
		return "设置\n\n" + m.settings.View() + "\n\n" + m.renderPreviewBlock()
	case tuiMCP:
		return "MCP 服务器\n\n" + m.mcpServers.View() + "\n\n" + m.renderPreviewBlock()
	case tuiSessions:
		return m.renderSessionsView()
	case tuiMemories:
		return "记忆\n\n" + m.memories.View() + "\n\n" + m.renderPreviewBlock()
	case tuiSQLite:
		return fmt.Sprintf("数据库: %s  [1 chat / 2 config / 3 memory]\n\n表结构\n%s\n\n查询结果\n%s\n\n%s", m.sqlDatabase, m.sqlTables.View(), m.sqlRows.View(), m.renderPreviewBlock())
	default:
		return ""
	}
}

func (m tuiModel) renderPreviewBlock() string {
	value := strings.TrimRight(m.preview.Value(), "\n")
	if strings.TrimSpace(value) == "" {
		return ""
	}
	title := "  详情"
	if m.focus == tuiFocusDetail {
		title = "▶ 详情"
	}
	return tuiDetailStyle.Render(title) + "\n" + value
}

func (m tuiModel) previewStartYOffset() int {
	prefix := ""
	switch m.active {
	case tuiFiles:
		prefix = fmt.Sprintf("路径: %s\n\n%s\n\n", m.currentPath, m.filesTable.View())
	case tuiProviders:
		prefix = "提供商\n\n" + m.providers.View() + "\n\n"
	case tuiSettings:
		prefix = "设置\n\n" + m.settings.View() + "\n\n"
	case tuiMCP:
		prefix = "MCP 服务器\n\n" + m.mcpServers.View() + "\n\n"
	case tuiMemories:
		prefix = "记忆\n\n" + m.memories.View() + "\n\n"
	case tuiSQLite:
		prefix = fmt.Sprintf("数据库: %s  [1 chat / 2 config / 3 memory]\n\n表结构\n%s\n\n查询结果\n%s\n\n", m.sqlDatabase, m.sqlTables.View(), m.sqlRows.View())
	default:
		return 0
	}
	return strings.Count(prefix, "\n")
}

func (m *tuiModel) focusDetailPreview() {
	if strings.TrimSpace(m.preview.Value()) == "" {
		return
	}
	m.focus = tuiFocusDetail
	m.syncFocusedComponent()
	m.content.SetContent(m.renderActiveView())
	m.content.SetYOffset(m.previewStartYOffset())
}

func (m tuiModel) renderDashboard() string {
	lines := []string{
		"连接",
		fmt.Sprintf("  设备/模式: %s / %s", m.status.deviceName, m.status.mode),
		fmt.Sprintf("  队列/等待: %d / %d", m.status.queueSize, m.status.pendingRequests),
		"",
	}
	if m.status.serviceError != "" {
		lines = append(lines,
			"服务",
			"  状态: 启动失败",
			"  错误: "+m.status.serviceError,
			"  处理: 关闭占用进程，或改用 go run . 7655",
			"",
		)
	}
	lines = append(lines,
		"地址",
		fmt.Sprintf("  HTTP/WebUI: http://%s:%d", m.localIP, m.server.port),
		fmt.Sprintf("  WebSocket: ws://%s:%d%s", m.localIP, m.server.port, wsPath),
		fmt.Sprintf("  OpenAI: http://%s:%d/v1", m.localIP, m.server.port),
		m.renderBonjourLine(),
		"",
		"快速开始",
		"  设备端可自动发现，也可以手动填入地址。",
	)
	return strings.Join(lines, "\n")
}

func (m tuiModel) renderBonjourLine() string {
	if m.status.serviceError != "" {
		return "  Bonjour: 未发布"
	}
	return fmt.Sprintf("  Bonjour: %s -> %d", bonjourServiceType, m.server.port)
}

func (m *tuiModel) syncContentViewport() {
	m.content.SetContent(m.renderActiveView())
	if m.content.PastBottom() {
		m.content.GotoBottom()
	}
}

func (m *tuiModel) resetContentViewport() {
	m.content.SetContent(m.renderActiveView())
	m.content.GotoTop()
}

func (m *tuiModel) syncFocusedComponent() {
	for _, t := range []*table.Model{&m.filesTable, &m.providers, &m.settings, &m.mcpServers, &m.sessions, &m.memories, &m.sqlTables, &m.sqlRows} {
		t.Blur()
	}
	if m.focus != tuiFocusContent {
		return
	}
	switch m.active {
	case tuiFiles:
		m.filesTable.Focus()
	case tuiProviders:
		m.providers.Focus()
	case tuiSettings:
		m.settings.Focus()
	case tuiMCP:
		m.mcpServers.Focus()
	case tuiSessions:
		if m.sessionMode == tuiSessionModeList {
			m.sessions.Focus()
		}
	case tuiMemories:
		m.memories.Focus()
	case tuiSQLite:
		if len(m.sqlRows.Rows()) > 0 {
			m.sqlRows.Focus()
		} else {
			m.sqlTables.Focus()
		}
	}
}

func (m *tuiModel) syncActiveViewFromNav() {
	item, ok := m.nav.SelectedItem().(navItem)
	if !ok {
		return
	}
	m.active = item.view
}

func (m tuiModel) renderHelp() string {
	return tuiRenderTouchActions(m.touchHelpActions(), m.rightContentWidth())
}

func (m *tuiModel) nextView() {
	m.active = tuiView((int(m.active) + 1) % tuiViewCount)
	m.nav.Select(int(m.active))
	m.resetContentViewport()
}

func (m *tuiModel) previousView() {
	next := int(m.active) - 1
	if next < 0 {
		next = tuiViewCount - 1
	}
	m.active = tuiView(next)
	m.nav.Select(next)
	m.resetContentViewport()
}

func (m *tuiModel) handleContentKey(key string) tea.Cmd {
	if m.focus == tuiFocusDetail {
		return m.handleDetailKey(key)
	}
	switch key {
	case "r":
		return m.refreshActiveView()
	case "enter":
		return m.enterSelected()
	case "up", "k":
		if m.active == tuiSessions {
			switch m.sessionMode {
			case tuiSessionModeMessages:
				m.selectPreviousSessionMessage()
				return nil
			case tuiSessionModeMessageDetail:
				m.selectPreviousSessionDetail()
				return nil
			}
		}
	case "down", "j":
		if m.active == tuiSessions {
			switch m.sessionMode {
			case tuiSessionModeMessages:
				m.selectNextSessionMessage()
				return nil
			case tuiSessionModeMessageDetail:
				m.selectNextSessionDetail()
				return nil
			}
		}
	case "h", "[":
		if m.active == tuiSessions && m.sessionMode == tuiSessionModeMessageDetail {
			return m.switchSelectedSessionMessageVersion(-1)
		}
	case "l", "]":
		if m.active == tuiSessions && m.sessionMode == tuiSessionModeMessageDetail {
			return m.switchSelectedSessionMessageVersion(1)
		}
	case "p":
		if m.active == tuiFiles {
			return m.promptFilesPath()
		}
		if m.active == tuiMCP {
			return m.editSelectedMCPPolicies()
		}
	case "P", "shift+p":
		if m.active == tuiMCP {
			return m.editSelectedMCPToolPolicy()
		}
	case "b":
		if m.active == tuiFiles {
			m.currentPath = parentDevicePath(m.currentPath)
			return m.loadFiles(m.currentPath)
		}
	case "d":
		return m.downloadSelectedFile()
	case "u":
		if m.active == tuiFiles {
			return m.uploadFile()
		}
	case "x":
		return m.deleteSelected()
	case "n":
		return m.createSelectedKind()
	case "a":
		if m.active == tuiProviders {
			return m.addProvider()
		}
		if m.active == tuiMCP {
			return m.addMCPServer()
		}
	case "m":
		if m.active == tuiProviders {
			return m.addProviderModel()
		}
	case "M", "shift+m":
		if m.active == tuiProviders {
			return m.editSelectedProviderModel()
		}
	case "e":
		if m.active == tuiProviders {
			return m.editSelectedProvider()
		}
		if m.active == tuiMCP {
			return m.editSelectedMCPServer()
		}
		if m.active == tuiSettings {
			return m.editSelectedSetting()
		}
		if m.active == tuiMemories {
			return m.editSelectedMemory()
		}
		if m.active == tuiSessions && m.sessionMode == tuiSessionModeMessageDetail {
			return m.editSelectedSessionDetail()
		}
	case "t":
		if m.active == tuiMCP {
			return m.toggleSelectedMCPServerChat()
		}
	case "g":
		if m.active == tuiMCP {
			return m.toggleMCPGlobalChatTools()
		}
	case "1", "2", "3":
		if m.active == tuiSQLite {
			m.setSQLDatabase(key)
			return m.loadSQLiteTables()
		}
	case "q":
		if m.active == tuiSQLite {
			return m.promptSQLiteQuery(false)
		}
	case "w":
		if m.active == tuiSQLite {
			return m.promptSQLiteQuery(true)
		}
	case "pgup", "ctrl+u":
		m.content.HalfViewUp()
	case "pgdown", "ctrl+d":
		m.content.HalfViewDown()
	case "home":
		m.content.GotoTop()
	case "end":
		m.content.GotoBottom()
	}
	return nil
}

func (m *tuiModel) handleDetailKey(key string) tea.Cmd {
	switch key {
	case "r":
		return m.refreshActiveView()
	case "up", "k":
		if !m.scrollDetailUp(1) {
			m.returnDetailFocusToContent()
		}
	case "down", "j":
		if !m.scrollDetailDown(1) {
			m.returnDetailFocusToContent()
		}
	case "pgup", "ctrl+u":
		m.scrollDetailUp(maxInt(1, m.content.Height/2))
	case "pgdown", "ctrl+d":
		m.scrollDetailDown(maxInt(1, m.content.Height/2))
	case "home":
		m.content.SetYOffset(m.previewStartYOffset())
	case "end":
		m.content.GotoBottom()
	case "enter":
		m.returnDetailFocusToContent()
	}
	return nil
}

func (m *tuiModel) scrollDetailUp(lines int) bool {
	previewTop := m.previewStartYOffset()
	if m.content.YOffset <= previewTop {
		m.content.SetYOffset(previewTop)
		return false
	}
	before := m.content.YOffset
	m.content.SetYOffset(maxInt(previewTop, m.content.YOffset-lines))
	return m.content.YOffset != before
}

func (m *tuiModel) scrollDetailDown(lines int) bool {
	before := m.content.YOffset
	m.content.ScrollDown(lines)
	return m.content.YOffset != before
}

func (m *tuiModel) returnDetailFocusToContent() {
	m.focus = tuiFocusContent
	m.syncFocusedComponent()
}

func (m tuiModel) updateActiveContentComponent(msg tea.Msg) (tuiModel, tea.Cmd) {
	var cmd tea.Cmd
	if m.focus == tuiFocusDetail {
		return m, nil
	}
	switch m.active {
	case tuiFiles:
		m.filesTable, cmd = m.filesTable.Update(msg)
	case tuiProviders:
		m.providers, cmd = m.providers.Update(msg)
	case tuiSettings:
		m.settings, cmd = m.settings.Update(msg)
	case tuiMCP:
		m.mcpServers, cmd = m.mcpServers.Update(msg)
	case tuiSessions:
		if m.sessionMode == tuiSessionModeList {
			m.sessions, cmd = m.sessions.Update(msg)
		} else if sessionMessageNavigationKey(msg) {
			return m, nil
		} else {
			m.content, cmd = m.content.Update(msg)
		}
	case tuiMemories:
		m.memories, cmd = m.memories.Update(msg)
	case tuiSQLite:
		if len(m.sqlRows.Rows()) > 0 {
			m.sqlRows, cmd = m.sqlRows.Update(msg)
		} else {
			m.sqlTables, cmd = m.sqlTables.Update(msg)
		}
	default:
		m.content, cmd = m.content.Update(msg)
	}
	return m, cmd
}

func sessionMessageNavigationKey(msg tea.Msg) bool {
	keyMsg, ok := msg.(tea.KeyMsg)
	if !ok {
		return false
	}
	switch keyMsg.String() {
	case "up", "k", "down", "j":
		return true
	default:
		return false
	}
}

func (m *tuiModel) setMessage(text string, style lipgloss.Style) {
	m.message = text
	m.messageStyle = style
}

func newTUIForm(groups ...*huh.Group) *huh.Form {
	keymap := huh.NewDefaultKeyMap()
	keymap.Quit = key.NewBinding(key.WithKeys("esc"), key.WithHelp("esc", "取消"))
	return huh.NewForm(groups...).WithKeyMap(keymap).WithShowHelp(false)
}

func tuiSelectOptionsWithCurrent(options []huh.Option[string], current string) []huh.Option[string] {
	result := append([]huh.Option[string](nil), options...)
	current = strings.TrimSpace(current)
	if current == "" {
		return result
	}
	for _, option := range result {
		if option.Value == current {
			return result
		}
	}
	return append(result, huh.NewOption("当前自定义: "+current, current))
}

func tuiProviderAPIFormatOptions() []huh.Option[string] {
	return []huh.Option[string]{
		huh.NewOption("OpenAI 兼容 (openai-compatible)", "openai-compatible"),
		huh.NewOption("OpenAI Responses (openai-responses)", "openai-responses"),
		huh.NewOption("Gemini (gemini)", "gemini"),
		huh.NewOption("Anthropic (anthropic)", "anthropic"),
	}
}

func tuiProviderProxyModeOptions() []huh.Option[string] {
	return []huh.Option[string]{
		huh.NewOption("继承全局 (inherit)", "inherit"),
		huh.NewOption("禁用 (disabled)", "disabled"),
		huh.NewOption("启用 (enabled)", "enabled"),
	}
}

func tuiProviderProxyTypeOptions() []huh.Option[string] {
	return []huh.Option[string]{
		huh.NewOption("HTTP (http)", "http"),
		huh.NewOption("SOCKS5 (socks5)", "socks5"),
	}
}

func tuiModelKindOptions() []huh.Option[string] {
	return []huh.Option[string]{
		huh.NewOption("聊天 (chat)", "chat"),
		huh.NewOption("图片生成 (image)", "image"),
		huh.NewOption("嵌入 (embedding)", "embedding"),
		huh.NewOption("重排 (rerank)", "rerank"),
		huh.NewOption("语音转文字 (speechToText)", "speechToText"),
		huh.NewOption("文字转语音 (textToSpeech)", "textToSpeech"),
	}
}

func tuiInputModalityOptions() []huh.Option[string] {
	return []huh.Option[string]{
		huh.NewOption("文本 (text)", "text"),
		huh.NewOption("图像 (image)", "image"),
		huh.NewOption("音频 (audio)", "audio"),
		huh.NewOption("文件 (file)", "file"),
	}
}

func tuiOutputModalityOptions() []huh.Option[string] {
	return []huh.Option[string]{
		huh.NewOption("文本 (text)", "text"),
		huh.NewOption("图像 (image)", "image"),
		huh.NewOption("音频 (audio)", "audio"),
	}
}

func tuiModelCapabilityOptions() []huh.Option[string] {
	return []huh.Option[string]{
		huh.NewOption("工具调用 (toolCalling)", "toolCalling"),
		huh.NewOption("推理 (reasoning)", "reasoning"),
		huh.NewOption("流式输出 (streaming)", "streaming"),
		huh.NewOption("JSON 模式 (jsonMode)", "jsonMode"),
		huh.NewOption("嵌入 (embedding)", "embedding"),
		huh.NewOption("语音转文字 (speechToText)", "speechToText"),
		huh.NewOption("文字转语音 (textToSpeech)", "textToSpeech"),
	}
}

func tuiRequestBodyOverrideModeOptions() []huh.Option[string] {
	return []huh.Option[string]{
		huh.NewOption("键值覆盖 (keyValue)", "keyValue"),
		huh.NewOption("表达式 (expression)", "expression"),
		huh.NewOption("原始 JSON (rawJSON)", "rawJSON"),
	}
}

func tuiSelectionValues(values []string, fallback []string) []string {
	result := make([]string, 0, len(values))
	seen := map[string]bool{}
	for _, value := range values {
		trimmed := strings.TrimSpace(value)
		if trimmed == "" || seen[trimmed] {
			continue
		}
		seen[trimmed] = true
		result = append(result, trimmed)
	}
	if len(result) == 0 {
		return append([]string(nil), fallback...)
	}
	return result
}

func (m tuiModel) refreshActiveView() tea.Cmd {
	switch m.active {
	case tuiFiles:
		return m.loadFiles(m.currentPath)
	case tuiProviders:
		return m.loadProviders()
	case tuiSettings:
		return m.loadSettings()
	case tuiMCP:
		return m.loadMCPServers()
	case tuiSessions:
		if m.sessionMode != tuiSessionModeList {
			if id := asString(m.activeSession["id"]); id != "" {
				return m.loadSession(id)
			}
		}
		return m.loadSessions()
	case tuiMemories:
		return m.loadMemories()
	case tuiSQLite:
		return m.loadSQLiteTables()
	default:
		return nil
	}
}

func (m tuiModel) refreshActiveViewIfConnected() tea.Cmd {
	connected, _ := m.server.getConnectionStatus()
	if !connected {
		return nil
	}
	return m.refreshActiveView()
}

func (m *tuiModel) enterSelected() tea.Cmd {
	switch m.active {
	case tuiFiles:
		row := m.filesTable.SelectedRow()
		if len(row) == 0 {
			return nil
		}
		item := m.selectedFileItem()
		name := row[0]
		if itemName := asString(item["name"]); itemName != "" {
			name = itemName
		}
		path := joinDevicePath(m.currentPath, name)
		if fileItemIsDirectory(item) || row[1] == "目录" {
			return m.loadFiles(path)
		}
		return m.readFile(path)
	case tuiProviders:
		return m.showSelectedProvider()
	case tuiSettings:
		return m.showSelectedSetting()
	case tuiMCP:
		return m.showSelectedMCPServer()
	case tuiSessions:
		return m.enterSessionSelection()
	case tuiMemories:
		return m.showSelectedMemory()
	case tuiSQLite:
		row := m.sqlTables.SelectedRow()
		if len(row) > 0 {
			sql := fmt.Sprintf("SELECT * FROM %s", quoteSQLiteIdentifierForTUI(row[0]))
			return m.runSQLiteQuery(sql, false)
		}
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
	if len(row) == 0 || row[1] == "目录" || fileItemIsDirectory(m.selectedFileItem()) {
		return nil
	}
	return m.readFile(joinDevicePath(m.currentPath, row[0]))
}

func (m *tuiModel) uploadFile() tea.Cmd {
	if m.active != tuiFiles {
		return nil
	}
	localPath := ""
	remotePath := m.currentPath
	form := newTUIForm(huh.NewGroup(
		huh.NewInput().Title("本地文件路径").Value(&localPath),
		huh.NewInput().Title("设备目标路径").Value(&remotePath),
	))
	return m.beginInlineForm("上传文件", form, func(m *tuiModel) tea.Cmd {
		return func() tea.Msg {
			localPath = strings.TrimSpace(localPath)
			remotePath = strings.TrimSpace(remotePath)
			if localPath == "" || remotePath == "" {
				return tuiCommandResultMsg{op: "files:upload", err: fmt.Errorf("本地文件路径和设备目标路径不能为空")}
			}

			data, err := os.ReadFile(localPath)
			if err != nil {
				return tuiCommandResultMsg{op: "files:upload", err: fmt.Errorf("读取本地文件失败: %w", err)}
			}
			response, err := m.server.sendCommandWithResponse(map[string]any{
				"command": "upload",
				"path":    remotePath,
				"data":    base64.StdEncoding.EncodeToString(data),
			}, 45*time.Second)
			return tuiCommandResultMsg{op: "files:upload", response: response, err: err}
		}
	})
}

func (m *tuiModel) promptFilesPath() tea.Cmd {
	path := m.currentPath
	form := newTUIForm(huh.NewGroup(
		huh.NewInput().Title("设备路径").Value(&path),
	))
	return m.beginInlineForm("跳转设备路径", form, func(m *tuiModel) tea.Cmd {
		return func() tea.Msg {
			path = strings.TrimSpace(path)
			if path == "" {
				path = "."
			}
			response, err := m.server.sendCommandWithResponse(map[string]any{"command": "list", "path": path}, 20*time.Second)
			return tuiCommandResultMsg{op: "files:list:" + path, response: response, err: err}
		}
	})
}

func (m tuiModel) loadProviders() tea.Cmd {
	return m.markLoading(m.remoteCommand("providers:list", map[string]any{"command": "providers_list"}, 25*time.Second))
}

func (m *tuiModel) addProvider() tea.Cmd {
	name := ""
	baseURL := ""
	apiKey := ""
	apiFormat := "openai-compatible"
	headerOverrides := "{}"
	proxyMode := "inherit"
	proxyType := "http"
	proxyHost := ""
	proxyPort := "8080"
	proxyUsername := ""
	proxyPassword := ""
	editProxy := false

	submitProvider := func(m *tuiModel) tea.Cmd {
		payload, err := buildProviderUpsertPayload(providerUpsertInput{
			Name:            name,
			BaseURL:         baseURL,
			APIFormat:       apiFormat,
			APIKey:          apiKey,
			HeaderOverrides: headerOverrides,
			ProxyMode:       proxyMode,
			ProxyType:       proxyType,
			ProxyHost:       proxyHost,
			ProxyPort:       proxyPort,
			ProxyUsername:   proxyUsername,
			ProxyPassword:   proxyPassword,
		})
		if err != nil {
			return tuiMessageCommand(tuiCommandResultMsg{op: "providers:upsert", err: err})
		}
		return func() tea.Msg {
			response, err := m.server.sendCommandWithResponse(payload, 35*time.Second)
			return tuiCommandResultMsg{op: "providers:upsert", response: response, err: err}
		}
	}

	form := newTUIForm(huh.NewGroup(
		huh.NewInput().Title("名称").Value(&name),
		huh.NewInput().Title("API URL").Value(&baseURL),
		huh.NewInput().Title("API Key").EchoMode(huh.EchoModePassword).Value(&apiKey),
		huh.NewSelect[string]().
			Title("API 格式").
			Options(tuiProviderAPIFormatOptions()...).
			Value(&apiFormat).
			Height(4),
		huh.NewInput().Title("Header Overrides JSON").Value(&headerOverrides),
		huh.NewConfirm().Title("编辑代理高级配置").Affirmative("编辑").Negative("跳过").Value(&editProxy),
	))
	return m.beginInlineForm("新增 Provider", form, func(m *tuiModel) tea.Cmd {
		if !editProxy {
			return submitProvider(m)
		}
		proxyForm := newTUIForm(huh.NewGroup(
			huh.NewSelect[string]().
				Title("代理模式").
				Options(tuiProviderProxyModeOptions()...).
				Value(&proxyMode).
				Height(3),
			huh.NewSelect[string]().
				Title("代理类型").
				Options(tuiProviderProxyTypeOptions()...).
				Value(&proxyType).
				Height(2),
			huh.NewInput().Title("代理主机").Value(&proxyHost),
			huh.NewInput().Title("代理端口").Value(&proxyPort),
			huh.NewInput().Title("代理用户名").Value(&proxyUsername),
			huh.NewInput().Title("代理密码").EchoMode(huh.EchoModePassword).Value(&proxyPassword),
		))
		return m.beginInlineForm("Provider 代理高级配置", proxyForm, submitProvider)
	})
}

func (m *tuiModel) editSelectedProvider() tea.Cmd {
	row := m.providers.SelectedRow()
	if len(row) == 0 {
		return nil
	}
	providerID := row[0]
	provider := m.findProviderRow(providerID)
	name := asString(provider["name"])
	baseURL := asString(provider["baseURL"])
	apiFormat := asString(provider["apiFormat"])
	apiKey := ""
	headerOverrides := providerHeaderOverridesText(provider)
	proxyMode := providerProxyMode(provider)
	proxyType := providerProxyField(provider, "type", "http")
	proxyHost := providerProxyField(provider, "host", "")
	proxyPort := providerProxyField(provider, "port", "8080")
	proxyUsername := providerProxyField(provider, "username", "")
	proxyPassword := providerProxyField(provider, "password", "")
	editProxy := false

	submitProvider := func(m *tuiModel) tea.Cmd {
		payload, err := buildProviderUpsertPayload(providerUpsertInput{
			ProviderID:      providerID,
			Name:            name,
			BaseURL:         baseURL,
			APIFormat:       apiFormat,
			APIKey:          apiKey,
			HeaderOverrides: headerOverrides,
			ProxyMode:       proxyMode,
			ProxyType:       proxyType,
			ProxyHost:       proxyHost,
			ProxyPort:       proxyPort,
			ProxyUsername:   proxyUsername,
			ProxyPassword:   proxyPassword,
		})
		if err != nil {
			return tuiMessageCommand(tuiCommandResultMsg{op: "providers:upsert", err: err})
		}
		return func() tea.Msg {
			response, err := m.server.sendCommandWithResponse(payload, 35*time.Second)
			return tuiCommandResultMsg{op: "providers:upsert", response: response, err: err}
		}
	}

	form := newTUIForm(huh.NewGroup(
		huh.NewInput().Title("名称").Value(&name),
		huh.NewInput().Title("API URL").Value(&baseURL),
		huh.NewSelect[string]().
			Title("API 格式").
			Options(tuiSelectOptionsWithCurrent(tuiProviderAPIFormatOptions(), apiFormat)...).
			Value(&apiFormat).
			Height(5),
		huh.NewInput().Title("API Key（留空则不修改）").EchoMode(huh.EchoModePassword).Value(&apiKey),
		huh.NewInput().Title("Header Overrides JSON").Value(&headerOverrides),
		huh.NewConfirm().Title("编辑代理高级配置").Affirmative("编辑").Negative("跳过").Value(&editProxy),
	))
	return m.beginInlineForm("编辑 Provider", form, func(m *tuiModel) tea.Cmd {
		if !editProxy {
			return submitProvider(m)
		}
		proxyForm := newTUIForm(huh.NewGroup(
			huh.NewSelect[string]().
				Title("代理模式").
				Options(tuiProviderProxyModeOptions()...).
				Value(&proxyMode).
				Height(3),
			huh.NewSelect[string]().
				Title("代理类型").
				Options(tuiProviderProxyTypeOptions()...).
				Value(&proxyType).
				Height(2),
			huh.NewInput().Title("代理主机").Value(&proxyHost),
			huh.NewInput().Title("代理端口").Value(&proxyPort),
			huh.NewInput().Title("代理用户名").Value(&proxyUsername),
			huh.NewInput().Title("代理密码（留空则清除）").EchoMode(huh.EchoModePassword).Value(&proxyPassword),
		))
		return m.beginInlineForm("Provider 代理高级配置", proxyForm, submitProvider)
	})
}

func (m *tuiModel) addProviderModel() tea.Cmd {
	row := m.providers.SelectedRow()
	if len(row) == 0 {
		return nil
	}
	providerID := row[0]
	modelName := ""
	displayName := ""
	kind := "chat"
	inputModalities := []string{"text"}
	outputModalities := []string{"text"}
	capabilities := []string{"toolCalling"}
	requestBodyOverrideMode := "keyValue"
	rawRequestBodyJSON := ""
	requestBodyControls := "[]"
	overrideParameters := "{}"
	pricing := "{}"
	form := newTUIForm(huh.NewGroup(
		huh.NewInput().Title("模型 ID").Value(&modelName),
		huh.NewInput().Title("显示名称").Value(&displayName),
		huh.NewSelect[string]().
			Title("类型").
			Options(tuiModelKindOptions()...).
			Value(&kind).
			Height(6),
		huh.NewMultiSelect[string]().
			Title("输入模态").
			Options(tuiInputModalityOptions()...).
			Value(&inputModalities).
			Height(4),
		huh.NewMultiSelect[string]().
			Title("输出模态").
			Options(tuiOutputModalityOptions()...).
			Value(&outputModalities).
			Height(3),
		huh.NewMultiSelect[string]().
			Title("能力").
			Options(tuiModelCapabilityOptions()...).
			Value(&capabilities).
			Height(7),
		huh.NewSelect[string]().
			Title("请求体覆盖模式").
			Options(tuiRequestBodyOverrideModeOptions()...).
			Value(&requestBodyOverrideMode).
			Height(3),
		huh.NewText().Title("Raw Request Body JSON（留空则清除）").Value(&rawRequestBodyJSON),
		huh.NewText().Title("请求体控件 JSON 数组").Value(&requestBodyControls),
		huh.NewText().Title("Override Parameters JSON").Value(&overrideParameters),
		huh.NewText().Title("Pricing JSON").Value(&pricing),
	))
	return m.beginInlineForm("新增 Provider 模型", form, func(m *tuiModel) tea.Cmd {
		payload, err := buildProviderModelUpsertPayload(providerModelUpsertInput{
			ProviderID:              providerID,
			ModelName:               modelName,
			DisplayName:             displayName,
			Kind:                    kind,
			InputModalities:         strings.Join(inputModalities, ","),
			OutputModalities:        strings.Join(outputModalities, ","),
			Capabilities:            strings.Join(capabilities, ","),
			RequestBodyOverrideMode: requestBodyOverrideMode,
			RawRequestBodyJSON:      rawRequestBodyJSON,
			RequestBodyControls:     requestBodyControls,
			OverrideParameters:      overrideParameters,
			Pricing:                 pricing,
			IsActivated:             true,
		})
		if err != nil {
			return tuiMessageCommand(tuiCommandResultMsg{op: "providers:model", err: err})
		}
		return func() tea.Msg {
			response, err := m.server.sendCommandWithResponse(payload, 35*time.Second)
			return tuiCommandResultMsg{op: "providers:model_upsert", response: response, err: err}
		}
	})
}

func (m *tuiModel) editSelectedProviderModel() tea.Cmd {
	row := m.providers.SelectedRow()
	if len(row) == 0 {
		return nil
	}
	providerID := row[0]
	provider := m.findProviderRow(providerID)
	models := asMapSlice(provider["models"])
	if len(models) == 0 {
		return func() tea.Msg {
			return tuiCommandResultMsg{op: "providers:model", err: fmt.Errorf("当前 Provider 没有可编辑模型")}
		}
	}
	modelID := asString(models[0]["id"])
	options := make([]huh.Option[string], 0, len(models))
	for index, model := range models {
		id := asString(model["id"])
		if id == "" {
			continue
		}
		options = append(options, huh.NewOption(providerModelOptionLabel(model, index), id))
	}
	if len(options) == 0 {
		return func() tea.Msg {
			return tuiCommandResultMsg{op: "providers:model", err: fmt.Errorf("当前 Provider 的模型缺少 ID，无法编辑")}
		}
	}

	selectForm := newTUIForm(huh.NewGroup(
		huh.NewSelect[string]().
			Title("选择要编辑的模型").
			Options(options...).
			Value(&modelID).
			Height(maxInt(4, minInt(len(options), 12))),
	))
	return m.beginInlineForm("选择 Provider 模型", selectForm, func(m *tuiModel) tea.Cmd {
		model := findProviderModelRow(models, modelID)
		if len(model) == 0 {
			return tuiMessageCommand(tuiCommandResultMsg{op: "providers:model", err: fmt.Errorf("未找到模型")})
		}

		modelName := asString(model["modelName"])
		displayName := asString(model["displayName"])
		kind := asString(model["kind"])
		if kind == "" {
			kind = "chat"
		}
		inputModalities := tuiSelectionValues(asStringSlice(model["inputModalities"]), []string{"text"})
		outputModalities := tuiSelectionValues(asStringSlice(model["outputModalities"]), []string{"text"})
		capabilities := tuiSelectionValues(asStringSlice(model["capabilities"]), nil)
		requestBodyOverrideMode := asString(model["requestBodyOverrideMode"])
		if requestBodyOverrideMode == "" {
			requestBodyOverrideMode = "keyValue"
		}
		rawRequestBodyJSON := asString(model["rawRequestBodyJSON"])
		requestBodyControls := providerModelRequestBodyControlsText(model)
		overrideParameters := providerModelOverrideText(model)
		pricing := providerModelPricingText(model)
		isActivated := model["isActivated"] == nil || asBool(model["isActivated"])

		editForm := newTUIForm(huh.NewGroup(
			huh.NewInput().Title("模型 ID").Value(&modelName),
			huh.NewInput().Title("显示名称").Value(&displayName),
			huh.NewConfirm().Title("启用模型").Affirmative("启用").Negative("停用").Value(&isActivated),
			huh.NewSelect[string]().
				Title("类型").
				Options(tuiSelectOptionsWithCurrent(tuiModelKindOptions(), kind)...).
				Value(&kind).
				Height(6),
			huh.NewMultiSelect[string]().
				Title("输入模态").
				Options(tuiInputModalityOptions()...).
				Value(&inputModalities).
				Height(4),
			huh.NewMultiSelect[string]().
				Title("输出模态").
				Options(tuiOutputModalityOptions()...).
				Value(&outputModalities).
				Height(3),
			huh.NewMultiSelect[string]().
				Title("能力").
				Options(tuiModelCapabilityOptions()...).
				Value(&capabilities).
				Height(7),
			huh.NewSelect[string]().
				Title("请求体覆盖模式").
				Options(tuiSelectOptionsWithCurrent(tuiRequestBodyOverrideModeOptions(), requestBodyOverrideMode)...).
				Value(&requestBodyOverrideMode).
				Height(4),
			huh.NewText().Title("Raw Request Body JSON（留空则清除）").Value(&rawRequestBodyJSON),
			huh.NewText().Title("请求体控件 JSON 数组").Value(&requestBodyControls),
			huh.NewText().Title("Override Parameters JSON").Value(&overrideParameters),
			huh.NewText().Title("Pricing JSON").Value(&pricing),
		))
		return m.beginInlineForm("编辑 Provider 模型", editForm, func(m *tuiModel) tea.Cmd {
			payload, err := buildProviderModelUpsertPayload(providerModelUpsertInput{
				ProviderID:              providerID,
				ModelID:                 modelID,
				ModelName:               modelName,
				DisplayName:             displayName,
				Kind:                    kind,
				InputModalities:         strings.Join(inputModalities, ","),
				OutputModalities:        strings.Join(outputModalities, ","),
				Capabilities:            strings.Join(capabilities, ","),
				RequestBodyOverrideMode: requestBodyOverrideMode,
				RawRequestBodyJSON:      rawRequestBodyJSON,
				RequestBodyControls:     requestBodyControls,
				OverrideParameters:      overrideParameters,
				Pricing:                 pricing,
				IsActivated:             isActivated,
			})
			if err != nil {
				return tuiMessageCommand(tuiCommandResultMsg{op: "providers:model", err: err})
			}
			return func() tea.Msg {
				response, err := m.server.sendCommandWithResponse(payload, 35*time.Second)
				return tuiCommandResultMsg{op: "providers:model_upsert", response: response, err: err}
			}
		})
	})
}

func (m tuiModel) findProviderRow(providerID string) map[string]any {
	for _, provider := range m.providerRows {
		if asString(provider["id"]) == providerID {
			return provider
		}
	}
	return map[string]any{}
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
				return tuiCommandResultMsg{op: "preview", response: map[string]any{"status": "ok", "preview": providerPreview(provider), "focus_detail": true}}
			}
		}
		return tuiCommandResultMsg{op: "preview", err: fmt.Errorf("未找到提供商")}
	}
}

func (m tuiModel) loadSettings() tea.Cmd {
	return m.markLoading(m.remoteCommand("settings:list", map[string]any{"command": "app_config_list"}, 25*time.Second))
}

func (m tuiModel) showSelectedSetting() tea.Cmd {
	row := m.settings.SelectedRow()
	if len(row) == 0 {
		return nil
	}
	key := row[0]
	return func() tea.Msg {
		for _, setting := range m.settingRows {
			if asString(setting["key"]) == key {
				return tuiCommandResultMsg{op: "preview", response: map[string]any{"status": "ok", "preview": settingPreview(setting), "focus_detail": true}}
			}
		}
		return tuiCommandResultMsg{op: "preview", err: fmt.Errorf("未找到配置")}
	}
}

func (m *tuiModel) editSelectedSetting() tea.Cmd {
	row := m.settings.SelectedRow()
	if len(row) == 0 {
		return nil
	}
	key := row[0]
	settingType := row[2]
	currentValue := row[4]
	for _, setting := range m.settingRows {
		if asString(setting["key"]) == key {
			settingType = asString(setting["type"])
			currentValue = asString(setting["value_text"])
			break
		}
	}
	value := currentValue
	form := newTUIForm(huh.NewGroup(
		huh.NewInput().
			Title(fmt.Sprintf("%s (%s)", key, settingType)).
			Description("布尔值可填 true/false，数字按原类型解析，文本保持原样。").
			Value(&value),
	))
	return m.beginInlineForm("修改配置", form, func(m *tuiModel) tea.Cmd {
		return func() tea.Msg {
			response, err := m.server.sendCommandWithResponse(map[string]any{
				"command": "app_config_set",
				"key":     key,
				"value":   strings.TrimSpace(value),
			}, 25*time.Second)
			return tuiCommandResultMsg{op: "settings:set", response: response, err: err}
		}
	})
}

func (m tuiModel) loadSessions() tea.Cmd {
	return m.markLoading(m.remoteCommand("sessions:list", map[string]any{"command": "sessions_list"}, 25*time.Second))
}

func (m tuiModel) loadSelectedSession() tea.Cmd {
	row := m.sessions.SelectedRow()
	if len(row) == 0 {
		return nil
	}
	return m.loadSession(row[0])
}

func (m tuiModel) loadSession(sessionID string) tea.Cmd {
	payload := map[string]any{"command": "session_get", "session_id": sessionID}
	return m.markLoading(m.remoteCommand("sessions:get", payload, 30*time.Second))
}

func (m tuiModel) loadMemories() tea.Cmd {
	return m.markLoading(m.remoteCommand("memories:list", map[string]any{"command": "memories_list"}, 30*time.Second))
}

func (m tuiModel) loadSQLiteTables() tea.Cmd {
	payload := map[string]any{"command": "list_sqlite_tables", "database": m.sqlDatabase}
	return m.markLoading(m.remoteCommand("sqlite:tables", payload, 30*time.Second))
}

func (m *tuiModel) promptSQLiteQuery(mutating bool) tea.Cmd {
	sql := "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view')"
	if mutating {
		sql = "UPDATE table_name SET column_name = ? WHERE id = ?"
	}
	parametersJSON := "[]"
	maxRows := "50"
	returningMaxRows := "50"
	allowWithoutWhere := false
	title := "SQLite 查询"
	if mutating {
		title = "SQLite 写入"
	}
	fields := []huh.Field{
		huh.NewText().Title("SQL").Value(&sql),
		huh.NewText().Title("Parameters JSON 数组").Value(&parametersJSON),
	}
	if mutating {
		fields = append(fields,
			huh.NewConfirm().
				Title("允许 UPDATE/DELETE 不带 WHERE").
				Affirmative("允许").
				Negative("保持保护").
				Value(&allowWithoutWhere),
			huh.NewInput().Title("RETURNING 最大行数").Value(&returningMaxRows),
		)
	} else {
		fields = append(fields, huh.NewInput().Title("最大返回行数").Value(&maxRows))
	}
	form := newTUIForm(huh.NewGroup(fields...))
	return m.beginInlineForm(title, form, func(m *tuiModel) tea.Cmd {
		op := "sqlite:query"
		command := "query_sqlite"
		if mutating {
			op = "sqlite:mutate"
			command = "mutate_sqlite"
		}
		parameters, err := parseOptionalJSONArray(parametersJSON, "SQL Parameters")
		if err != nil {
			return tuiMessageCommand(tuiCommandResultMsg{op: op, err: err})
		}
		return func() tea.Msg {
			response, err := m.server.sendCommandWithResponse(map[string]any{
				"command":             command,
				"database":            m.sqlDatabase,
				"sql":                 sql,
				"allow_without_where": allowWithoutWhere,
				"returning_max_rows":  normalizedSQLiteRowLimit(returningMaxRows),
				"max_rows":            normalizedSQLiteRowLimit(maxRows),
				"parameters":          parameters,
			}, 60*time.Second)
			return tuiCommandResultMsg{op: op, response: response, err: err}
		}
	})
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

func (m *tuiModel) deleteSelected() tea.Cmd {
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
	case tuiMCP:
		return m.deleteSelectedMCPServer()
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

func (m *tuiModel) createSelectedKind() tea.Cmd {
	switch m.active {
	case tuiFiles:
		path := m.currentPath
		form := newTUIForm(huh.NewGroup(huh.NewInput().Title("新目录路径").Value(&path)))
		return m.beginInlineForm("新建目录", form, func(m *tuiModel) tea.Cmd {
			return func() tea.Msg {
				response, err := m.server.sendCommandWithResponse(map[string]any{"command": "mkdir", "path": strings.TrimSpace(path)}, 30*time.Second)
				return tuiCommandResultMsg{op: "files:mkdir", response: response, err: err}
			}
		})
	case tuiSessions:
		name := "新的对话"
		form := newTUIForm(huh.NewGroup(huh.NewInput().Title("会话名称").Value(&name)))
		return m.beginInlineForm("新建会话", form, func(m *tuiModel) tea.Cmd {
			return func() tea.Msg {
				response, err := m.server.sendCommandWithResponse(map[string]any{"command": "session_create", "name": strings.TrimSpace(name)}, 30*time.Second)
				return tuiCommandResultMsg{op: "sessions:create", response: response, err: err}
			}
		})
	case tuiMemories:
		return m.confirmAndRun("确认重嵌入全部记忆？", "memories:reembed", map[string]any{"command": "memories_reembed_all"}, 15*time.Minute)
	}
	return nil
}

func (m *tuiModel) editSelectedMemory() tea.Cmd {
	memory := m.selectedMemory()
	if len(memory) == 0 {
		return nil
	}
	memoryID := asString(memory["id"])
	content := asString(memory["content"])
	form := newTUIForm(huh.NewGroup(huh.NewText().Title("记忆内容").Value(&content)))
	return m.beginInlineForm("编辑记忆", form, func(m *tuiModel) tea.Cmd {
		return func() tea.Msg {
			response, err := m.server.sendCommandWithResponse(map[string]any{"command": "memory_update", "memory_id": memoryID, "content": content}, 45*time.Second)
			return tuiCommandResultMsg{op: "memories:update", response: response, err: err}
		}
	})
}

func (m tuiModel) showSelectedMemory() tea.Cmd {
	memory := m.selectedMemory()
	if len(memory) == 0 {
		return nil
	}
	return func() tea.Msg {
		return tuiCommandResultMsg{op: "preview", response: map[string]any{"status": "ok", "preview": memoryPreview(memory), "focus_detail": true}}
	}
}

func (m *tuiModel) confirmAndRun(title, op string, payload map[string]any, timeout time.Duration) tea.Cmd {
	ok := false
	form := newTUIForm(huh.NewGroup(huh.NewConfirm().Title(title).Value(&ok)))
	return m.beginInlineForm("确认操作", form, func(m *tuiModel) tea.Cmd {
		if !ok {
			return tuiMessageCommand(tuiCommandResultMsg{op: "noop", response: map[string]any{"status": "ok", "message": "已取消"}})
		}
		return func() tea.Msg {
			response, err := m.server.sendCommandWithResponse(payload, timeout)
			return tuiCommandResultMsg{op: op, response: response, err: err}
		}
	})
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
	case msg.op == "files:upload":
		m.preview.SetValue(uploadPreview(msg.response))
		m.setMessage("文件已上传；按 r 可刷新目录", tuiOKStyle)
	case msg.op == "providers:list":
		m.applyProviders(msg.response)
	case msg.op == "providers:save":
		m.setMessage("提供商已保存", tuiOKStyle)
	case msg.op == "providers:upsert":
		if provider, ok := msg.response["provider"].(map[string]any); ok {
			m.preview.SetValue(providerPreview(provider))
		} else {
			m.preview.SetValue(firstNonEmpty(asString(msg.response["message"]), "Provider 已保存"))
		}
		m.setMessage("Provider 已保存；按 r 可刷新列表", tuiOKStyle)
	case msg.op == "providers:model_upsert":
		if provider, ok := msg.response["provider"].(map[string]any); ok {
			m.preview.SetValue(providerPreview(provider))
		} else if model, ok := msg.response["model"].(map[string]any); ok {
			m.preview.SetValue(strings.Join(providerModelSummary(map[string]any{"models": []any{model}}), "\n"))
		} else {
			m.preview.SetValue(firstNonEmpty(asString(msg.response["message"]), "模型已保存"))
		}
		m.setMessage("模型已保存；按 r 可刷新列表", tuiOKStyle)
	case msg.op == "settings:list":
		m.applySettings(msg.response)
	case msg.op == "settings:set":
		if setting, ok := msg.response["setting"].(map[string]any); ok {
			m.preview.SetValue(settingPreview(setting))
		} else {
			m.preview.SetValue(firstNonEmpty(asString(msg.response["message"]), "配置已保存"))
		}
		m.setMessage("配置已保存；按 r 可刷新列表", tuiOKStyle)
	case msg.op == "mcp:list":
		m.applyMCPServers(msg.response)
	case msg.op == "mcp:detail":
		m.preview.SetValue(mcpServerPreview(asMapSlice(msg.response["rows"])))
		m.focusDetailPreview()
	case strings.HasPrefix(msg.op, "mcp:"):
		m.preview.SetValue(mcpMutationPreview(msg.response))
		m.setMessage("MCP 操作已执行；按 r 可刷新列表", tuiOKStyle)
	case msg.op == "sessions:list":
		m.applySessions(msg.response)
	case msg.op == "sessions:get":
		m.applySessionDetail(msg.response)
	case msg.op == "sessions:update_messages":
		if messages, ok := msg.response["messages"]; ok {
			preferredMessageID := ""
			if current := m.selectedSessionMessageMap(); len(current) > 0 {
				preferredMessageID = asString(current["id"])
			}
			m.setSessionMessagesFromAll(asMapSlice(messages), preferredMessageID)
		}
		m.setMessage("会话消息已更新", tuiOKStyle)
		m.keepSelectedSessionDetailVisible()
	case msg.op == "memories:list":
		m.applyMemories(msg.response)
	case msg.op == "sqlite:tables":
		m.applySQLiteTables(msg.response)
	case msg.op == "sqlite:query":
		m.applySQLiteRows(msg.response)
	case msg.op == "sqlite:mutate":
		m.preview.SetValue(sqliteMutationPreview(msg.response))
		m.setMessage("SQL 写入已执行", tuiOKStyle)
	case msg.op == "preview":
		m.preview.SetValue(asString(msg.response["preview"]))
		if asBool(msg.response["focus_detail"]) {
			m.focusDetailPreview()
		}
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
	program := tea.NewProgram(model, tea.WithAltScreen(), tea.WithMouseAllMotion(), tea.WithoutSignalHandler())
	relayDone := make(chan struct{})
	go func() {
		select {
		case <-ctxDone:
			program.Send(tuiExternalQuitMsg{})
		case <-relayDone:
		}
	}()
	_, err := program.Run()
	close(relayDone)
	if err == nil {
		select {
		case <-ctxDone:
			return context.Canceled
		default:
		}
	}
	return err
}
