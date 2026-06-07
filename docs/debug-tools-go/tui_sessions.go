package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

var (
	tuiSessionMetaStyle       = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	tuiSessionUserBubbleStyle = lipgloss.NewStyle().
					Border(lipgloss.RoundedBorder()).
					BorderForeground(lipgloss.Color("69")).
					Foreground(lipgloss.Color("250")).
					Padding(0, 1)
	tuiSessionAssistantBubbleStyle = lipgloss.NewStyle().
					Border(lipgloss.RoundedBorder()).
					BorderForeground(lipgloss.Color("42")).
					Foreground(lipgloss.Color("250")).
					Padding(0, 1)
	tuiSessionSystemBubbleStyle = lipgloss.NewStyle().
					Border(lipgloss.RoundedBorder()).
					BorderForeground(lipgloss.Color("214")).
					Foreground(lipgloss.Color("250")).
					Padding(0, 1)
	tuiSessionToolBubbleStyle = lipgloss.NewStyle().
					Border(lipgloss.RoundedBorder()).
					BorderForeground(lipgloss.Color("105")).
					Foreground(lipgloss.Color("250")).
					Padding(0, 1)
	tuiSessionErrorBubbleStyle = lipgloss.NewStyle().
					Border(lipgloss.RoundedBorder()).
					BorderForeground(lipgloss.Color("203")).
					Foreground(lipgloss.Color("250")).
					Padding(0, 1)
	tuiSessionSelectedBubbleStyle = lipgloss.NewStyle().
					Border(lipgloss.ThickBorder()).
					BorderForeground(lipgloss.Color("219")).
					Foreground(lipgloss.Color("230")).
					Bold(true).
					Padding(0, 1)
)

func (m tuiModel) renderSessionsView() string {
	switch m.sessionMode {
	case tuiSessionModeMessages:
		return m.renderSessionMessagesView()
	case tuiSessionModeMessageDetail:
		return m.renderSessionMessageDetailView()
	default:
		return "会话\n\n" + m.sessions.View()
	}
}

func (m tuiModel) renderSessionsHelp(common string) string {
	switch m.sessionMode {
	case tuiSessionModeMessages:
		return common + " | ↑↓ 选择气泡 | Enter 更多 | r 刷新当前会话"
	case tuiSessionModeMessageDetail:
		return common + " | ↑↓/PgUp/PgDn 滚动 | Esc 返回气泡列表"
	default:
		return common + " | Enter 查看消息 | n 新建会话 | x 删除"
	}
}

func (m *tuiModel) handleSessionBack() bool {
	switch m.sessionMode {
	case tuiSessionModeMessageDetail:
		m.sessionMode = tuiSessionModeMessages
		m.content.GotoTop()
		return true
	case tuiSessionModeMessages:
		m.sessionMode = tuiSessionModeList
		m.content.GotoTop()
		return true
	default:
		return false
	}
}

func (m *tuiModel) enterSessionSelection() tea.Cmd {
	switch m.sessionMode {
	case tuiSessionModeMessages:
		if len(m.sessionMessages) == 0 {
			return nil
		}
		m.sessionMode = tuiSessionModeMessageDetail
		m.content.GotoTop()
		return nil
	case tuiSessionModeMessageDetail:
		return nil
	default:
		return m.loadSelectedSession()
	}
}

func (m *tuiModel) selectPreviousSessionMessage() {
	if len(m.sessionMessages) == 0 {
		return
	}
	m.selectedSessionMessage = maxInt(0, m.selectedSessionMessage-1)
	m.keepSelectedSessionMessageVisible()
}

func (m *tuiModel) selectNextSessionMessage() {
	if len(m.sessionMessages) == 0 {
		return
	}
	m.selectedSessionMessage = minInt(len(m.sessionMessages)-1, m.selectedSessionMessage+1)
	m.keepSelectedSessionMessageVisible()
}

func (m *tuiModel) keepSelectedSessionMessageVisible() {
	if m.content.Height <= 0 {
		return
	}
	// 气泡高度会随内容换行变化，这里用稳定估算让长会话里上下移动更跟手。
	target := maxInt(0, 4+m.selectedSessionMessage*5-m.content.Height/2)
	m.content.SetYOffset(target)
}

func (m *tuiModel) applySessionDetail(response map[string]any) {
	if session, ok := response["session"].(map[string]any); ok {
		m.activeSession = session
	} else {
		m.activeSession = map[string]any{}
	}
	m.sessionMessages = asMapSlice(response["messages"])
	if len(m.sessionMessages) == 0 {
		m.selectedSessionMessage = 0
	} else {
		m.selectedSessionMessage = minInt(maxInt(0, m.selectedSessionMessage), len(m.sessionMessages)-1)
	}
	m.sessionMode = tuiSessionModeMessages
	m.preview.SetValue("")
	m.content.GotoTop()
	m.setMessage(fmt.Sprintf("已加载会话「%s」%d 条消息", sessionDisplayName(m.activeSession), len(m.sessionMessages)), tuiOKStyle)
}

func (m tuiModel) renderSessionMessagesView() string {
	lines := []string{
		fmt.Sprintf("会话 / %s", sessionDisplayName(m.activeSession)),
		tuiSessionMetaStyle.Render(fmt.Sprintf("%s | %d 条消息", asString(m.activeSession["id"]), len(m.sessionMessages))),
		"",
	}
	if len(m.sessionMessages) == 0 {
		lines = append(lines, tuiHelpStyle.Render("这个会话还没有消息。"))
		return strings.Join(lines, "\n")
	}

	for index, message := range m.sessionMessages {
		lines = append(lines, m.renderSessionMessageBubble(message, index, index == m.selectedSessionMessage))
	}
	return strings.Join(lines, "\n\n")
}

func (m tuiModel) renderSessionMessageDetailView() string {
	message := m.selectedSessionMessageMap()
	if len(message) == 0 {
		return "消息详情\n\n没有可查看的消息。"
	}

	lines := []string{
		fmt.Sprintf("消息详情 / %s / 第 %d 条", sessionDisplayName(m.activeSession), m.selectedSessionMessage+1),
		tuiSessionMetaStyle.Render(fmt.Sprintf("%s | %s", sessionRoleLabel(messageRole(message)), asString(message["id"]))),
		"",
		"正文",
		sessionMessageDetailContent(message),
	}

	if reasoning := strings.TrimSpace(asString(message["reasoningContent"])); reasoning != "" {
		lines = append(lines, "", "推理", reasoning)
	}
	if fullError := strings.TrimSpace(asString(message["fullErrorContent"])); fullError != "" && fullError != sessionMessageFullContent(message) {
		lines = append(lines, "", "完整错误", fullError)
	}

	extras := sessionMessageExtraLines(message)
	if len(extras) > 0 {
		lines = append(lines, "", "附加信息")
		lines = append(lines, extras...)
	}
	return strings.Join(lines, "\n")
}

func (m tuiModel) renderSessionMessageBubble(message map[string]any, index int, selected bool) string {
	role := messageRole(message)
	label := fmt.Sprintf("%s #%d", sessionRoleLabel(role), index+1)
	body := label + "\n" + sessionMessagePreview(message)

	width := maxInt(24, minInt(76, m.content.Width-8))
	style := sessionBubbleStyle(role)
	if selected {
		style = tuiSessionSelectedBubbleStyle
	}
	bubble := style.Width(width).Render(body)

	if role == "user" {
		return lipgloss.PlaceHorizontal(maxInt(width, m.content.Width), lipgloss.Right, bubble)
	}
	return lipgloss.PlaceHorizontal(maxInt(width, m.content.Width), lipgloss.Left, bubble)
}

func (m tuiModel) selectedSessionMessageMap() map[string]any {
	if len(m.sessionMessages) == 0 {
		return nil
	}
	index := minInt(maxInt(0, m.selectedSessionMessage), len(m.sessionMessages)-1)
	return m.sessionMessages[index]
}

func sessionBubbleStyle(role string) lipgloss.Style {
	switch role {
	case "user":
		return tuiSessionUserBubbleStyle
	case "system":
		return tuiSessionSystemBubbleStyle
	case "tool":
		return tuiSessionToolBubbleStyle
	case "error":
		return tuiSessionErrorBubbleStyle
	default:
		return tuiSessionAssistantBubbleStyle
	}
}

func sessionRoleLabel(role string) string {
	switch role {
	case "system":
		return "系统"
	case "user":
		return "用户"
	case "assistant":
		return "助手"
	case "tool":
		return "工具"
	case "error":
		return "错误"
	default:
		return "消息"
	}
}

func messageRole(message map[string]any) string {
	role := strings.TrimSpace(strings.ToLower(asString(message["role"])))
	if role == "" {
		return "assistant"
	}
	return role
}

func sessionDisplayName(session map[string]any) string {
	name := strings.TrimSpace(asString(session["name"]))
	if name == "" {
		return "未命名会话"
	}
	return name
}

func sessionInfoText(session map[string]any) string {
	parts := []string{}
	if strings.TrimSpace(asString(session["topicPrompt"])) != "" {
		parts = append(parts, "主题")
	}
	if strings.TrimSpace(asString(session["enhancedPrompt"])) != "" {
		parts = append(parts, "增强")
	}
	if count := len(sessionLorebookIDs(session)); count > 0 {
		parts = append(parts, fmt.Sprintf("世界书%d", count))
	}
	if count := len(asStringSlice(session["tagIDs"])); count > 0 {
		parts = append(parts, fmt.Sprintf("标签%d", count))
	}
	if strings.TrimSpace(asString(session["folderID"])) != "" {
		parts = append(parts, "文件夹")
	}
	if asBool(session["worldbookContextIsolationEnabled"]) {
		parts = append(parts, "隔离")
	}
	return truncateRunes(strings.Join(parts, " / "), 28)
}

func sessionLorebookIDs(session map[string]any) []string {
	if ids := asStringSlice(session["lorebookIDs"]); len(ids) > 0 {
		return ids
	}
	return asStringSlice(session["worldbookIDs"])
}

func sessionMessagePreview(message map[string]any) string {
	text := strings.TrimSpace(sessionMessageFullContent(message))
	if text == "" {
		return "（空消息）"
	}
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	preview := make([]string, 0, minInt(len(lines), 4))
	omitted := false
	for _, line := range lines {
		if len(preview) >= 4 {
			omitted = true
			break
		}
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if runeLen(trimmed) > 96 {
			omitted = true
		}
		preview = append(preview, truncateRunes(trimmed, 96))
	}
	if len(preview) == 0 {
		return "（空消息）"
	}
	if omitted && !strings.HasSuffix(preview[len(preview)-1], "…") {
		preview[len(preview)-1] += "…"
	}
	return strings.Join(preview, "\n")
}

func sessionMessageFullContent(message map[string]any) string {
	switch content := message["content"].(type) {
	case string:
		return content
	case []string:
		return sessionContentVersion(content, asInt(message["currentVersionIndex"]))
	case []any:
		versions := make([]string, 0, len(content))
		for _, item := range content {
			versions = append(versions, asString(item))
		}
		return sessionContentVersion(versions, asInt(message["currentVersionIndex"]))
	default:
		return asString(message["content"])
	}
}

func sessionMessageDetailContent(message map[string]any) string {
	content := sessionMessageFullContent(message)
	if strings.TrimSpace(content) == "" {
		return "（空消息）"
	}
	return content
}

func sessionContentVersion(versions []string, index int) string {
	if len(versions) == 0 {
		return ""
	}
	index = minInt(maxInt(0, index), len(versions)-1)
	return versions[index]
}

func sessionMessageExtraLines(message map[string]any) []string {
	var lines []string
	if requestedAt := strings.TrimSpace(asString(message["requestedAt"])); requestedAt != "" {
		lines = append(lines, "请求时间: "+requestedAt)
	}
	if names := asStringSlice(message["imageFileNames"]); len(names) > 0 {
		lines = append(lines, fmt.Sprintf("图片附件: %d 个", len(names)))
	}
	if names := asStringSlice(message["fileFileNames"]); len(names) > 0 {
		lines = append(lines, fmt.Sprintf("文件附件: %d 个", len(names)))
	}
	if audio := strings.TrimSpace(asString(message["audioFileName"])); audio != "" {
		lines = append(lines, "音频附件: "+audio)
	}
	if toolCalls := asAnySlice(message["toolCalls"]); len(toolCalls) > 0 {
		lines = append(lines, fmt.Sprintf("工具调用: %d 个", len(toolCalls)))
	}
	if tokenUsage, ok := message["tokenUsage"].(map[string]any); ok {
		if summary := sessionTokenUsageSummary(tokenUsage); summary != "" {
			lines = append(lines, "Token: "+summary)
		}
	}
	if model, ok := message["modelReference"].(map[string]any); ok {
		if name := strings.TrimSpace(asString(model["modelName"])); name != "" {
			lines = append(lines, "模型: "+name)
		}
	}
	return lines
}

func sessionTokenUsageSummary(tokenUsage map[string]any) string {
	parts := []string{}
	for _, item := range []struct {
		key   string
		label string
	}{
		{"promptTokens", "输入"},
		{"completionTokens", "输出"},
		{"thinkingTokens", "思考"},
		{"totalTokens", "总计"},
	} {
		if _, ok := tokenUsage[item.key]; ok {
			parts = append(parts, fmt.Sprintf("%s %d", item.label, asInt(tokenUsage[item.key])))
		}
	}
	return strings.Join(parts, " / ")
}

func truncateRunes(value string, maxLen int) string {
	runes := []rune(value)
	if len(runes) <= maxLen {
		return value
	}
	return string(runes[:maxLen-1]) + "…"
}

func runeLen(value string) int {
	return len([]rune(value))
}
