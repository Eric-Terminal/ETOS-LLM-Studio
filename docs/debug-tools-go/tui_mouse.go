package main

import (
	"strings"

	"github.com/charmbracelet/bubbles/table"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

type tuiRect struct {
	left   int
	top    int
	right  int
	bottom int
}

func (r tuiRect) contains(x, y int) bool {
	return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom
}

type tuiTouchAction struct {
	label string
	key   string
}

func (a tuiTouchAction) token() string {
	return "[" + a.label + "]"
}

func (m tuiModel) touchHelpActions() []tuiTouchAction {
	actions := []tuiTouchAction{
		{label: "←侧栏", key: "left"},
		{label: "→内容", key: "right"},
		{label: "Tab切页", key: "tab"},
		{label: "r刷新", key: "r"},
		{label: "Esc返回", key: "esc"},
		{label: "退出", key: "quit"},
	}

	if m.focus == tuiFocusNav {
		return append(actions,
			tuiTouchAction{label: "↑上页", key: "nav_up"},
			tuiTouchAction{label: "↓下页", key: "nav_down"},
			tuiTouchAction{label: "Enter进入", key: "nav_enter"},
		)
	}
	if m.focus == tuiFocusDetail {
		return append(actions,
			tuiTouchAction{label: "↑滚动", key: "up"},
			tuiTouchAction{label: "↓滚动", key: "down"},
			tuiTouchAction{label: "PgUp", key: "pgup"},
			tuiTouchAction{label: "PgDn", key: "pgdown"},
			tuiTouchAction{label: "Home", key: "home"},
			tuiTouchAction{label: "End", key: "end"},
			tuiTouchAction{label: "回表格", key: "enter"},
		)
	}

	switch m.active {
	case tuiFiles:
		return append(actions,
			tuiTouchAction{label: "p路径", key: "p"},
			tuiTouchAction{label: "Enter打开", key: "enter"},
			tuiTouchAction{label: "b上级", key: "b"},
			tuiTouchAction{label: "d下载", key: "d"},
			tuiTouchAction{label: "u上传", key: "u"},
			tuiTouchAction{label: "x删除", key: "x"},
			tuiTouchAction{label: "n新目录", key: "n"},
		)
	case tuiProviders:
		return append(actions,
			tuiTouchAction{label: "Enter详情", key: "enter"},
			tuiTouchAction{label: "a新增Provider", key: "a"},
			tuiTouchAction{label: "e编辑Provider", key: "e"},
			tuiTouchAction{label: "m新增模型", key: "m"},
			tuiTouchAction{label: "M编辑模型", key: "M"},
		)
	case tuiSettings:
		return append(actions,
			tuiTouchAction{label: "Enter详情", key: "enter"},
			tuiTouchAction{label: "e修改", key: "e"},
		)
	case tuiMCP:
		return append(actions,
			tuiTouchAction{label: "Enter详情", key: "enter"},
			tuiTouchAction{label: "a新增", key: "a"},
			tuiTouchAction{label: "e编辑", key: "e"},
			tuiTouchAction{label: "x删除", key: "x"},
			tuiTouchAction{label: "t聊天", key: "t"},
			tuiTouchAction{label: "P工具策略", key: "P"},
			tuiTouchAction{label: "pJSON策略", key: "p"},
			tuiTouchAction{label: "g总开关", key: "g"},
		)
	case tuiSessions:
		return append(actions, m.sessionTouchActions()...)
	case tuiMemories:
		return append(actions,
			tuiTouchAction{label: "Enter详情", key: "enter"},
			tuiTouchAction{label: "e编辑", key: "e"},
			tuiTouchAction{label: "x归档", key: "x"},
			tuiTouchAction{label: "n重嵌入", key: "n"},
		)
	case tuiSQLite:
		return append(actions,
			tuiTouchAction{label: "1聊天库", key: "1"},
			tuiTouchAction{label: "2配置库", key: "2"},
			tuiTouchAction{label: "3记忆库", key: "3"},
			tuiTouchAction{label: "q查询", key: "q"},
			tuiTouchAction{label: "w写入", key: "w"},
		)
	default:
		return actions
	}
}

func (m tuiModel) sessionTouchActions() []tuiTouchAction {
	switch m.sessionMode {
	case tuiSessionModeMessages:
		return []tuiTouchAction{
			{label: "↑上一条", key: "up"},
			{label: "↓下一条", key: "down"},
			{label: "Enter更多", key: "enter"},
			{label: "r刷新会话", key: "r"},
		}
	case tuiSessionModeMessageDetail:
		return []tuiTouchAction{
			{label: "↑上区块", key: "up"},
			{label: "↓下区块", key: "down"},
			{label: "h前版本", key: "h"},
			{label: "l后版本", key: "l"},
			{label: "e编辑", key: "e"},
			{label: "PgUp", key: "pgup"},
			{label: "PgDn", key: "pgdown"},
		}
	default:
		return []tuiTouchAction{
			{label: "Enter消息", key: "enter"},
			{label: "n新会话", key: "n"},
			{label: "x删除", key: "x"},
		}
	}
}

func tuiRenderTouchActions(actions []tuiTouchAction, width int) string {
	if len(actions) == 0 {
		return ""
	}
	width = maxInt(20, width)
	lines := []string{}
	current := ""
	for _, action := range actions {
		token := action.token()
		if current == "" {
			current = token
			continue
		}
		next := current + " " + token
		if ansi.StringWidth(next) > width {
			lines = append(lines, current)
			current = token
		} else {
			current = next
		}
	}
	if current != "" {
		lines = append(lines, current)
	}
	return strings.Join(lines, "\n")
}

func (m *tuiModel) handleMouse(msg tea.MouseMsg) tea.Cmd {
	if mouseIsWheel(msg) {
		return m.handleContentMouse(msg)
	}
	if msg.Action != tea.MouseActionPress || msg.Button != tea.MouseButtonLeft {
		return nil
	}
	if action, ok := m.touchHelpActionAt(msg); ok {
		return m.runTouchAction(action)
	}
	if m.mouseInNavPanel(msg) {
		return m.handleNavMousePress(msg)
	}
	if m.mouseInContentViewport(msg) {
		return m.handleContentMousePress(msg)
	}
	return nil
}

func mouseIsWheel(msg tea.MouseMsg) bool {
	switch msg.Button { //nolint:exhaustive
	case tea.MouseButtonWheelUp, tea.MouseButtonWheelDown, tea.MouseButtonWheelLeft, tea.MouseButtonWheelRight:
		return true
	default:
		return false
	}
}

func (m *tuiModel) handleContentMouse(msg tea.MouseMsg) tea.Cmd {
	if !m.mouseInContentViewport(msg) {
		return nil
	}
	var cmd tea.Cmd
	m.content, cmd = m.content.Update(msg)
	return cmd
}

func (m *tuiModel) handleContentMousePress(msg tea.MouseMsg) tea.Cmd {
	m.focus = tuiFocusContent
	m.syncFocusedComponent()
	line := m.contentLineAtMouse(msg)

	switch m.active {
	case tuiFiles:
		if m.selectTableRowAtLine(&m.filesTable, 2, line) {
			m.syncContentViewport()
			return nil
		}
	case tuiProviders:
		if m.selectTableRowAtLine(&m.providers, 2, line) {
			m.syncContentViewport()
			return nil
		}
	case tuiSettings:
		if m.selectTableRowAtLine(&m.settings, 2, line) {
			m.syncContentViewport()
			return nil
		}
	case tuiMCP:
		if m.selectTableRowAtLine(&m.mcpServers, 2, line) {
			m.syncContentViewport()
			return nil
		}
	case tuiSessions:
		if m.handleSessionContentMousePress(line) {
			m.syncContentViewport()
			return nil
		}
	case tuiMemories:
		if m.selectTableRowAtLine(&m.memories, 2, line) {
			m.syncContentViewport()
			return nil
		}
	case tuiSQLite:
		if m.handleSQLiteContentMousePress(line) {
			m.syncContentViewport()
			return nil
		}
	}

	if strings.TrimSpace(m.preview.Value()) != "" && line >= m.previewStartYOffset() {
		m.focusDetailPreview()
	}
	m.syncContentViewport()
	return nil
}

func (m *tuiModel) handleSQLiteContentMousePress(line int) bool {
	sqlTablesHeader := 3
	if m.selectTableRowAtLine(&m.sqlTables, sqlTablesHeader, line) {
		return true
	}
	sqlRowsHeader := sqlTablesHeader + lineCount(m.sqlTables.View()) + 2
	return m.selectTableRowAtLine(&m.sqlRows, sqlRowsHeader, line)
}

func (m *tuiModel) handleSessionContentMousePress(line int) bool {
	switch m.sessionMode {
	case tuiSessionModeList:
		return m.selectTableRowAtLine(&m.sessions, 2, line)
	case tuiSessionModeMessages:
		return m.selectSessionMessageAtLine(line)
	case tuiSessionModeMessageDetail:
		return m.selectSessionDetailAtLine(line)
	default:
		return false
	}
}

func (m *tuiModel) selectSessionMessageAtLine(line int) bool {
	elements := m.sessionMessageViewElements()
	start := 0
	for elementIndex, element := range elements {
		end := start + lineCount(element) - 1
		if elementIndex >= 3 && line >= start && line <= end {
			m.selectedSessionMessage = elementIndex - 3
			return true
		}
		start = end + 2
	}
	return false
}

func (m *tuiModel) selectSessionDetailAtLine(line int) bool {
	elements, sectionIndexes := m.sessionMessageDetailViewElements()
	for sectionIndex, elementIndex := range sectionIndexes {
		start := 0
		for index := 0; index < elementIndex; index++ {
			start += lineCount(elements[index])
		}
		end := start + lineCount(elements[elementIndex]) - 1
		if line >= start && line <= end {
			m.selectedSessionDetail = sectionIndex
			return true
		}
	}
	return false
}

func (m *tuiModel) selectTableRowAtLine(target *table.Model, headerLine int, line int) bool {
	rowOffset := line - headerLine - 1
	if rowOffset < 0 || rowOffset >= target.Height() {
		return false
	}
	rowIndex := tuiTableVisibleStart(*target) + rowOffset
	if rowIndex < 0 || rowIndex >= len(target.Rows()) {
		return false
	}
	target.SetCursor(rowIndex)
	return true
}

func tuiTableVisibleStart(target table.Model) int {
	return maxInt(0, target.Cursor()-target.Height())
}

func (m *tuiModel) handleNavMousePress(msg tea.MouseMsg) tea.Cmd {
	index, ok := m.navItemIndexAtMouse(msg)
	if !ok {
		return nil
	}
	previous := m.active
	m.nav.Select(index)
	m.syncActiveViewFromNav()
	m.focus = tuiFocusContent
	m.syncFocusedComponent()
	if previous != m.active {
		m.resetContentViewport()
		return m.markTouchLoading(m.refreshActiveViewIfConnected(), "nav")
	}
	m.syncContentViewport()
	return nil
}

func (m tuiModel) navItemIndexAtMouse(msg tea.MouseMsg) (int, bool) {
	lines := strings.Split(ansi.Strip(m.View()), "\n")
	if msg.Y < 0 || msg.Y >= len(lines) {
		return 0, false
	}
	prefix := ansi.Cut(lines[msg.Y], 0, m.navContentWidth()+tuiPanelHorizontalFrame)
	items := m.nav.VisibleItems()
	start, end := m.nav.Paginator.GetSliceBounds(len(items))
	for index := start; index < end; index++ {
		item, ok := items[index].(navItem)
		if !ok {
			continue
		}
		if strings.Contains(prefix, item.title) || strings.Contains(prefix, item.desc) {
			return index, true
		}
	}
	return 0, false
}

func (m tuiModel) touchHelpActionAt(msg tea.MouseMsg) (tuiTouchAction, bool) {
	lines := strings.Split(ansi.Strip(m.View()), "\n")
	if msg.Y < 0 || msg.Y >= len(lines) {
		return tuiTouchAction{}, false
	}
	line := lines[msg.Y]
	for _, action := range m.touchHelpActions() {
		start, end, ok := tuiCellRangeOfSubstring(line, action.token())
		if ok && msg.X >= start && msg.X < end {
			return action, true
		}
	}
	return tuiTouchAction{}, false
}

func tuiCellRangeOfSubstring(line, needle string) (int, int, bool) {
	byteIndex := strings.Index(line, needle)
	if byteIndex < 0 {
		return 0, 0, false
	}
	start := ansi.StringWidth(line[:byteIndex])
	end := start + ansi.StringWidth(needle)
	return start, end, true
}

func (m *tuiModel) runTouchAction(action tuiTouchAction) tea.Cmd {
	var cmd tea.Cmd
	switch action.key {
	case "quit":
		return tea.Quit
	case "left":
		m.focus = tuiFocusNav
		m.syncFocusedComponent()
	case "right", "nav_enter":
		m.focus = tuiFocusContent
		m.syncFocusedComponent()
	case "tab":
		m.nextView()
		m.focus = tuiFocusContent
		m.syncFocusedComponent()
		cmd = m.refreshActiveViewIfConnected()
	case "esc":
		cmd = m.handleTouchEscape()
	case "nav_up":
		cmd = m.moveNavSelection(-1)
	case "nav_down":
		cmd = m.moveNavSelection(1)
	default:
		if m.focus == tuiFocusNav {
			m.focus = tuiFocusContent
			m.syncFocusedComponent()
		}
		cmd = m.handleContentKey(action.key)
	}
	m.syncContentViewport()
	return m.markTouchLoading(cmd, action.key)
}

func (m *tuiModel) handleTouchEscape() tea.Cmd {
	if m.focus == tuiFocusDetail {
		m.focus = tuiFocusContent
		m.syncFocusedComponent()
		return nil
	}
	if m.active == tuiSessions && m.focus == tuiFocusContent && m.handleSessionBack() {
		m.syncFocusedComponent()
		return nil
	}
	if m.focus == tuiFocusContent {
		m.focus = tuiFocusNav
		m.syncFocusedComponent()
	}
	return nil
}

func (m *tuiModel) moveNavSelection(delta int) tea.Cmd {
	previous := m.active
	if delta < 0 {
		m.nav.CursorUp()
	} else {
		m.nav.CursorDown()
	}
	m.syncActiveViewFromNav()
	if previous != m.active {
		m.syncFocusedComponent()
		m.resetContentViewport()
		return m.refreshActiveViewIfConnected()
	}
	return nil
}

func (m *tuiModel) markTouchLoading(cmd tea.Cmd, key string) tea.Cmd {
	if cmd != nil && key != "quit" {
		m.isLoading = m.activeForm == nil
	}
	return cmd
}

func (m tuiModel) contentLineAtMouse(msg tea.MouseMsg) int {
	return msg.Y - m.contentViewportRect().top + m.content.YOffset
}

func (m tuiModel) mouseInContentViewport(msg tea.MouseMsg) bool {
	return m.contentViewportRect().contains(msg.X, msg.Y)
}

func (m tuiModel) contentViewportRect() tuiRect {
	top := 4
	rightOuterLeft := m.navContentWidth() + tuiPanelHorizontalFrame + tuiPanelGapWidth + 1
	contentLeft := rightOuterLeft + 2
	return tuiRect{
		left:   contentLeft,
		top:    top,
		right:  contentLeft + m.content.Width - 1,
		bottom: top + m.content.Height - 1,
	}
}

func (m tuiModel) mouseInNavPanel(msg tea.MouseMsg) bool {
	top := 3
	left := 1
	right := m.navContentWidth() + tuiPanelHorizontalFrame - 1
	bottom := top + maxInt(1, m.boxHeight()-2) - 1
	return tuiRect{left: left, top: top, right: right, bottom: bottom}.contains(msg.X, msg.Y)
}
