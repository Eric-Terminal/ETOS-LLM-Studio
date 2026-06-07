package main

import (
	"fmt"
	"sort"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"
)

type tuiSessionDetailKind string

const (
	tuiSessionDetailContent   tuiSessionDetailKind = "content"
	tuiSessionDetailReasoning tuiSessionDetailKind = "reasoning"
	tuiSessionDetailError     tuiSessionDetailKind = "error"
	tuiSessionDetailInfo      tuiSessionDetailKind = "info"
)

type tuiSessionDetailSection struct {
	kind     tuiSessionDetailKind
	title    string
	content  string
	style    lipgloss.Style
	editable bool
}

type tuiResponseAttemptVersionInfo struct {
	groupID          string
	currentAttemptID string
	currentIndex     int
	totalCount       int
}

type tuiResponseAttemptOrder struct {
	id            string
	explicitIndex int
	firstPosition int
}

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
	tuiSessionDetailContentStyle = lipgloss.NewStyle().
					Border(lipgloss.RoundedBorder()).
					BorderForeground(lipgloss.Color("69")).
					Foreground(lipgloss.Color("252")).
					Padding(0, 1)
	tuiSessionDetailReasoningStyle = lipgloss.NewStyle().
					Border(lipgloss.RoundedBorder()).
					BorderForeground(lipgloss.Color("214")).
					Foreground(lipgloss.Color("246")).
					Padding(0, 1)
	tuiSessionDetailErrorStyle = lipgloss.NewStyle().
					Border(lipgloss.RoundedBorder()).
					BorderForeground(lipgloss.Color("203")).
					Foreground(lipgloss.Color("252")).
					Padding(0, 1)
	tuiSessionDetailInfoStyle = lipgloss.NewStyle().
					Border(lipgloss.RoundedBorder()).
					BorderForeground(lipgloss.Color("105")).
					Foreground(lipgloss.Color("246")).
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
		return common + " | ↑↓ 选择正文/思考 | h/l 版本 | e 编辑 | PgUp/PgDn 滚动 | Esc 返回"
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
		m.selectedSessionDetail = 0
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

func (m *tuiModel) selectPreviousSessionDetail() {
	m.selectedSessionDetail = maxInt(0, m.selectedSessionDetail-1)
	m.keepSelectedSessionDetailVisible()
}

func (m *tuiModel) selectNextSessionDetail() {
	count := len(m.sessionDetailSections())
	if count == 0 {
		return
	}
	m.selectedSessionDetail = minInt(count-1, m.selectedSessionDetail+1)
	m.keepSelectedSessionDetailVisible()
}

func (m *tuiModel) switchSelectedSessionMessageVersion(delta int) tea.Cmd {
	if m.sessionMode != tuiSessionModeMessageDetail || delta == 0 {
		return nil
	}
	messageIndex := minInt(maxInt(0, m.selectedSessionMessage), len(m.sessionMessages)-1)
	if messageIndex < 0 || messageIndex >= len(m.sessionMessages) {
		return nil
	}
	selectedMessage := m.sessionMessages[messageIndex]
	if info, ok := responseAttemptVersionInfo(selectedMessage, m.allSessionMessagesForEditing()); ok {
		return m.switchSelectedResponseAttempt(info, delta)
	}

	selectedID := asString(selectedMessage["id"])
	updatedMessages := cloneSessionMessages(m.allSessionMessagesForEditing())
	targetIndex := sessionMessageIndexByID(updatedMessages, selectedID)
	if targetIndex < 0 {
		targetIndex = messageIndex
	}
	if targetIndex < 0 || targetIndex >= len(updatedMessages) || !switchSessionMessageVersion(updatedMessages[targetIndex], delta) {
		m.setMessage("当前消息没有可切换的其他版本", tuiWarnStyle)
		return nil
	}
	m.setSessionMessagesFromAll(updatedMessages, selectedID)
	m.keepSelectedSessionDetailVisible()

	sessionID := asString(m.activeSession["id"])
	if sessionID == "" {
		m.setMessage("当前会话缺少 ID，无法保存版本切换", tuiErrStyle)
		return nil
	}
	index, count := sessionMessageVersionPosition(updatedMessages[targetIndex])
	m.setMessage(fmt.Sprintf("已切换到版本 %d/%d，正在保存", index+1, count), tuiOKStyle)
	return m.markLoading(func() tea.Msg {
		response, err := m.server.sendCommandWithResponse(map[string]any{
			"command":    "session_update_messages",
			"session_id": sessionID,
			"messages":   updatedMessages,
		}, 45*time.Second)
		if response == nil {
			response = map[string]any{}
		}
		response["messages"] = updatedMessages
		return tuiCommandResultMsg{op: "sessions:update_messages", response: response, err: err}
	})
}

func (m *tuiModel) switchSelectedResponseAttempt(info tuiResponseAttemptVersionInfo, delta int) tea.Cmd {
	attempts := orderedResponseAttemptIDs(info.groupID, m.allSessionMessagesForEditing())
	nextIndex := info.currentIndex + delta
	if nextIndex < 0 || nextIndex >= len(attempts) {
		m.setMessage("当前消息没有可切换的其他版本", tuiWarnStyle)
		return nil
	}

	nextAttemptID := attempts[nextIndex]
	updatedMessages := selectResponseAttempt(nextAttemptID, info.groupID, m.allSessionMessagesForEditing())
	m.setSessionMessagesFromAll(updatedMessages, preferredResponseAttemptCarrierID(updatedMessages, info.groupID, nextAttemptID))
	m.keepSelectedSessionDetailVisible()

	sessionID := asString(m.activeSession["id"])
	if sessionID == "" {
		m.setMessage("当前会话缺少 ID，无法保存版本切换", tuiErrStyle)
		return nil
	}
	m.setMessage(fmt.Sprintf("已切换到回复尝试 %d/%d，正在保存", nextIndex+1, len(attempts)), tuiOKStyle)
	return m.markLoading(func() tea.Msg {
		response, err := m.server.sendCommandWithResponse(map[string]any{
			"command":    "session_update_messages",
			"session_id": sessionID,
			"messages":   updatedMessages,
		}, 45*time.Second)
		if response == nil {
			response = map[string]any{}
		}
		response["messages"] = updatedMessages
		return tuiCommandResultMsg{op: "sessions:update_messages", response: response, err: err}
	})
}

func (m *tuiModel) keepSelectedSessionMessageVisible() {
	if m.content.Height <= 0 {
		return
	}
	start, end, totalLines, ok := m.selectedSessionMessageLineRange()
	if !ok {
		return
	}
	bubbleHeight := end - start + 1
	target := start
	if bubbleHeight < m.content.Height {
		target = start - (m.content.Height-bubbleHeight)/2
	}
	maxOffset := maxInt(0, totalLines-m.content.Height)
	target = minInt(maxInt(0, target), maxOffset)
	m.content.SetYOffset(target)
}

func (m *tuiModel) keepSelectedSessionDetailVisible() {
	if m.content.Height <= 0 {
		return
	}
	start, end, totalLines, ok := m.selectedSessionDetailLineRange()
	if !ok {
		return
	}
	sectionHeight := end - start + 1
	target := start
	if sectionHeight < m.content.Height {
		target = start - (m.content.Height-sectionHeight)/2
	}
	maxOffset := maxInt(0, totalLines-m.content.Height)
	target = minInt(maxInt(0, target), maxOffset)
	m.content.SetYOffset(target)
}

func (m *tuiModel) applySessionDetail(response map[string]any) {
	if session, ok := response["session"].(map[string]any); ok {
		m.activeSession = session
	} else {
		m.activeSession = map[string]any{}
	}
	m.setSessionMessagesFromAll(asMapSlice(response["messages"]), "")
	m.selectedSessionDetail = minInt(maxInt(0, m.selectedSessionDetail), maxInt(0, len(m.sessionDetailSections())-1))
	m.sessionMode = tuiSessionModeMessages
	m.preview.SetValue("")
	m.content.GotoTop()
	if len(m.sessionMessages) == len(m.sessionAllMessages) {
		m.setMessage(fmt.Sprintf("已加载会话「%s」%d 条消息", sessionDisplayName(m.activeSession), len(m.sessionMessages)), tuiOKStyle)
	} else {
		m.setMessage(fmt.Sprintf("已加载会话「%s」%d 条可见消息 / %d 条完整历史", sessionDisplayName(m.activeSession), len(m.sessionMessages), len(m.sessionAllMessages)), tuiOKStyle)
	}
}

func (m tuiModel) renderSessionMessagesView() string {
	return strings.Join(m.sessionMessageViewElements(), "\n\n")
}

func (m tuiModel) sessionMessageViewElements() []string {
	elements := []string{
		fmt.Sprintf("会话 / %s", sessionDisplayName(m.activeSession)),
		tuiSessionMetaStyle.Render(fmt.Sprintf("%s | %d 条消息", asString(m.activeSession["id"]), len(m.sessionMessages))),
		"",
	}
	if len(m.sessionMessages) == 0 {
		elements = append(elements, tuiHelpStyle.Render("这个会话还没有消息。"))
		return elements
	}

	for index, message := range m.sessionMessages {
		elements = append(elements, m.renderSessionMessageBubble(message, index, index == m.selectedSessionMessage))
	}
	return elements
}

func (m tuiModel) selectedSessionMessageLineRange() (int, int, int, bool) {
	if len(m.sessionMessages) == 0 {
		return 0, 0, 0, false
	}

	selectedIndex := minInt(maxInt(0, m.selectedSessionMessage), len(m.sessionMessages)-1)
	selectedElementIndex := selectedIndex + 3
	elements := m.sessionMessageViewElements()
	if selectedElementIndex >= len(elements) {
		return 0, 0, 0, false
	}

	start := 0
	for index := 0; index < selectedElementIndex; index++ {
		start += lineCount(elements[index]) - 1
		start += 2
	}

	selectedLines := lineCount(elements[selectedElementIndex])
	totalLines := lineCount(strings.Join(elements, "\n\n"))
	return start, start + selectedLines - 1, totalLines, true
}

func (m tuiModel) renderSessionMessageDetailView() string {
	message := m.selectedSessionMessageMap()
	if len(message) == 0 {
		return "消息详情\n\n没有可查看的消息。"
	}

	elements, _ := m.sessionMessageDetailViewElements()
	return strings.Join(elements, "\n")
}

func (m tuiModel) sessionMessageDetailViewElements() ([]string, []int) {
	message := m.selectedSessionMessageMap()
	if len(message) == 0 {
		return []string{"消息详情", "", "没有可查看的消息。"}, nil
	}

	elements := []string{
		fmt.Sprintf("消息详情 / %s / 第 %d 条", sessionDisplayName(m.activeSession), m.selectedSessionMessage+1),
		tuiSessionMetaStyle.Render(sessionMessageDetailMetaWithAllMessages(message, m.allSessionMessagesForEditing())),
		"",
	}

	sectionElementIndexes := []int{}
	for index, section := range m.sessionDetailSections() {
		if len(elements) > 0 && elements[len(elements)-1] != "" {
			elements = append(elements, "")
		}
		selected := index == m.selectedSessionDetail
		sectionElementIndexes = append(sectionElementIndexes, len(elements))
		elements = append(elements, m.renderSessionDetailSection(section, selected))
	}
	return elements, sectionElementIndexes
}

func (m tuiModel) sessionDetailSections() []tuiSessionDetailSection {
	message := m.selectedSessionMessageMap()
	if len(message) == 0 {
		return nil
	}

	sections := []tuiSessionDetailSection{
		{
			kind:     tuiSessionDetailContent,
			title:    m.sessionMessageContentTitle(message),
			content:  sessionMessageDetailContent(message),
			style:    tuiSessionDetailContentStyle,
			editable: true,
		},
		{
			kind:     tuiSessionDetailReasoning,
			title:    "思考内容",
			content:  asString(message["reasoningContent"]),
			style:    tuiSessionDetailReasoningStyle,
			editable: true,
		},
	}
	if fullError := strings.TrimSpace(asString(message["fullErrorContent"])); fullError != "" && fullError != sessionMessageFullContent(message) {
		sections = append(sections, tuiSessionDetailSection{
			kind:    tuiSessionDetailError,
			title:   "完整错误",
			content: fullError,
			style:   tuiSessionDetailErrorStyle,
		})
	}
	if extras := sessionMessageExtraLines(message); len(extras) > 0 {
		sections = append(sections, tuiSessionDetailSection{
			kind:    tuiSessionDetailInfo,
			title:   "附加信息",
			content: strings.Join(extras, "\n"),
			style:   tuiSessionDetailInfoStyle,
		})
	}
	return sections
}

func (m tuiModel) renderSessionDetailSection(section tuiSessionDetailSection, selected bool) string {
	width := maxInt(36, minInt(100, m.content.Width-4))
	title := section.title
	style := section.style
	if selected {
		title = "▶ " + title
		style = style.Copy().
			Border(lipgloss.ThickBorder()).
			BorderForeground(lipgloss.Color("219")).
			Bold(true)
	}
	header := tuiTitleStyle.Render(title)
	body := strings.TrimSpace(section.content)
	if body == "" {
		body = "（空）"
	}
	return header + "\n" + style.Width(width).Render(body)
}

func (m tuiModel) selectedSessionDetailLineRange() (int, int, int, bool) {
	elements, sectionElementIndexes := m.sessionMessageDetailViewElements()
	if len(sectionElementIndexes) == 0 {
		return 0, 0, 0, false
	}
	selected := minInt(maxInt(0, m.selectedSessionDetail), len(sectionElementIndexes)-1)
	elementIndex := sectionElementIndexes[selected]

	start := 0
	for index := 0; index < elementIndex; index++ {
		start += lineCount(elements[index])
	}
	selectedLines := lineCount(elements[elementIndex])
	totalLines := lineCount(strings.Join(elements, "\n"))
	return start, start + selectedLines - 1, totalLines, true
}

func (m tuiModel) editSelectedSessionDetail() tea.Cmd {
	if m.sessionMode != tuiSessionModeMessageDetail {
		return nil
	}
	messageIndex := minInt(maxInt(0, m.selectedSessionMessage), len(m.sessionMessages)-1)
	if messageIndex < 0 || messageIndex >= len(m.sessionMessages) {
		return nil
	}
	selectedMessage := m.sessionMessages[messageIndex]
	sections := m.sessionDetailSections()
	if len(sections) == 0 {
		return nil
	}
	sectionIndex := minInt(maxInt(0, m.selectedSessionDetail), len(sections)-1)
	section := sections[sectionIndex]
	if !section.editable {
		return func() tea.Msg {
			return tuiCommandResultMsg{op: "noop", response: map[string]any{"status": "ok", "message": "当前区块仅供查看，不能编辑"}}
		}
	}
	sessionID := asString(m.activeSession["id"])
	if sessionID == "" {
		return func() tea.Msg {
			return tuiCommandResultMsg{op: "sessions:update_messages", err: fmt.Errorf("当前会话缺少 ID")}
		}
	}

	return tuiBlockingFormCommand(func(forms tuiFormRunner) tea.Msg {
		value := sessionDetailEditValue(selectedMessage, section.kind)
		form := forms.Form(huh.NewGroup(
			huh.NewText().Title(section.title).Value(&value),
		))
		if err := form.Run(); err != nil {
			return tuiFormErrorResult(err)
		}

		updatedMessages := cloneSessionMessages(m.allSessionMessagesForEditing())
		targetIndex := sessionMessageIndexByID(updatedMessages, asString(selectedMessage["id"]))
		if targetIndex < 0 {
			return tuiCommandResultMsg{op: "sessions:update_messages", err: fmt.Errorf("未找到当前消息")}
		}
		updateSessionMessageDetail(updatedMessages[targetIndex], section.kind, value)
		response, err := m.server.sendCommandWithResponse(map[string]any{
			"command":    "session_update_messages",
			"session_id": sessionID,
			"messages":   updatedMessages,
		}, 45*time.Second)
		if response == nil {
			response = map[string]any{}
		}
		response["messages"] = updatedMessages
		return tuiCommandResultMsg{op: "sessions:update_messages", response: response, err: err}
	})
}

func sessionDetailEditValue(message map[string]any, kind tuiSessionDetailKind) string {
	switch kind {
	case tuiSessionDetailReasoning:
		return asString(message["reasoningContent"])
	default:
		return sessionMessageFullContent(message)
	}
}

func updateSessionMessageDetail(message map[string]any, kind tuiSessionDetailKind, value string) {
	switch kind {
	case tuiSessionDetailReasoning:
		if strings.TrimSpace(value) == "" {
			delete(message, "reasoningContent")
		} else {
			message["reasoningContent"] = value
		}
	default:
		setSessionMessageContent(message, value)
	}
}

func setSessionMessageContent(message map[string]any, value string) {
	switch content := message["content"].(type) {
	case []any:
		versions := append([]any(nil), content...)
		index := minInt(maxInt(0, asInt(message["currentVersionIndex"])), maxInt(0, len(versions)-1))
		if len(versions) == 0 {
			versions = []any{value}
			index = 0
		} else {
			versions[index] = value
		}
		message["content"] = versions
		message["currentVersionIndex"] = index
	case []string:
		versions := append([]string(nil), content...)
		index := minInt(maxInt(0, asInt(message["currentVersionIndex"])), maxInt(0, len(versions)-1))
		if len(versions) == 0 {
			versions = []string{value}
			index = 0
		} else {
			versions[index] = value
		}
		message["content"] = versions
		message["currentVersionIndex"] = index
	default:
		message["content"] = value
	}
}

func cloneSessionMessages(messages []map[string]any) []map[string]any {
	result := make([]map[string]any, 0, len(messages))
	for _, message := range messages {
		cloned := make(map[string]any, len(message))
		for key, value := range message {
			switch typed := value.(type) {
			case []any:
				cloned[key] = append([]any(nil), typed...)
			case []string:
				cloned[key] = append([]string(nil), typed...)
			default:
				cloned[key] = value
			}
		}
		result = append(result, cloned)
	}
	return result
}

func (m tuiModel) renderSessionMessageBubble(message map[string]any, index int, selected bool) string {
	role := messageRole(message)
	label := fmt.Sprintf("%s #%d", sessionRoleLabel(role), index+1)
	if versionLabel := m.sessionMessageVersionLabel(message); versionLabel != "" {
		label += " · " + versionLabel
	}
	body := label + "\n" + sessionMessagePreview(message)

	width := sessionBubbleInnerWidth(body, maxInt(18, minInt(76, m.content.Width-10)))
	style := sessionBubbleStyle(role)
	if selected {
		style = tuiSessionSelectedBubbleStyle
	}
	bubble := style.Width(width).Render(body)

	if role == "user" {
		return rightAlignMultiline(bubble, maxInt(lipgloss.Width(bubble), m.content.Width-2))
	}
	return bubble
}

func (m tuiModel) selectedSessionMessageMap() map[string]any {
	if len(m.sessionMessages) == 0 {
		return nil
	}
	index := minInt(maxInt(0, m.selectedSessionMessage), len(m.sessionMessages)-1)
	return m.sessionMessages[index]
}

func sessionMessageDetailMeta(message map[string]any) string {
	return sessionMessageDetailMetaWithAllMessages(message, nil)
}

func sessionMessageDetailMetaWithAllMessages(message map[string]any, allMessages []map[string]any) string {
	parts := []string{sessionRoleLabel(messageRole(message))}
	if id := strings.TrimSpace(asString(message["id"])); id != "" {
		parts = append(parts, id)
	}
	if versionLabel := sessionMessageVersionLabelWithAllMessages(message, allMessages); versionLabel != "" {
		parts = append(parts, versionLabel)
	}
	return strings.Join(parts, " | ")
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
	versions := sessionContentVersions(message)
	index, _ := sessionMessageVersionPosition(message)
	return sessionContentVersion(versions, index)
}

func sessionMessageDetailContent(message map[string]any) string {
	content := sessionMessageFullContent(message)
	if strings.TrimSpace(content) == "" {
		return "（空消息）"
	}
	return content
}

func sessionMessageContentTitle(message map[string]any) string {
	if label := sessionMessageVersionLabel(message); label != "" {
		return "正文 · " + label
	}
	return "正文"
}

func (m tuiModel) sessionMessageContentTitle(message map[string]any) string {
	if label := m.sessionMessageVersionLabel(message); label != "" {
		return "正文 · " + label
	}
	return "正文"
}

func sessionMessageVersionLabel(message map[string]any) string {
	return sessionMessageVersionLabelWithAllMessages(message, nil)
}

func (m tuiModel) sessionMessageVersionLabel(message map[string]any) string {
	return sessionMessageVersionLabelWithAllMessages(message, m.allSessionMessagesForEditing())
}

func sessionMessageVersionLabelWithAllMessages(message map[string]any, allMessages []map[string]any) string {
	index, count := sessionMessageVersionPositionWithAllMessages(message, allMessages)
	if count <= 1 {
		return ""
	}
	return fmt.Sprintf("版本 %d/%d", index+1, count)
}

func sessionMessageVersionPosition(message map[string]any) (int, int) {
	return sessionMessageVersionPositionWithAllMessages(message, nil)
}

func sessionMessageVersionPositionWithAllMessages(message map[string]any, allMessages []map[string]any) (int, int) {
	if info, ok := responseAttemptVersionInfo(message, allMessages); ok {
		return info.currentIndex, info.totalCount
	}
	count := len(sessionContentVersions(message))
	if count == 0 {
		return 0, 0
	}
	index := minInt(maxInt(0, asInt(message["currentVersionIndex"])), count-1)
	return index, count
}

func switchSessionMessageVersion(message map[string]any, delta int) bool {
	index, count := sessionMessageVersionPosition(message)
	if count <= 1 {
		return false
	}
	next := minInt(maxInt(0, index+delta), count-1)
	if next == index {
		return false
	}
	message["currentVersionIndex"] = next
	return true
}

func (m tuiModel) allSessionMessagesForEditing() []map[string]any {
	if len(m.sessionAllMessages) > 0 {
		return m.sessionAllMessages
	}
	return m.sessionMessages
}

func (m *tuiModel) setSessionMessagesFromAll(messages []map[string]any, preferredMessageID string) {
	m.sessionAllMessages = messages
	m.sessionMessages = visibleSessionMessages(messages)
	if len(m.sessionMessages) == 0 {
		m.selectedSessionMessage = 0
		return
	}
	if preferredMessageID != "" {
		if index := sessionMessageIndexByID(m.sessionMessages, preferredMessageID); index >= 0 {
			m.selectedSessionMessage = index
			return
		}
	}
	m.selectedSessionMessage = minInt(maxInt(0, m.selectedSessionMessage), len(m.sessionMessages)-1)
}

func sessionMessageIndexByID(messages []map[string]any, id string) int {
	if strings.TrimSpace(id) == "" {
		return -1
	}
	for index, message := range messages {
		if asString(message["id"]) == id {
			return index
		}
	}
	return -1
}

func visibleSessionMessages(messages []map[string]any) []map[string]any {
	selectedByGroup := selectedResponseAttemptIDsByGroup(messages)
	visible := make([]map[string]any, 0, len(messages))
	for _, message := range messages {
		groupID := asString(message["responseGroupID"])
		attemptID := asString(message["responseAttemptID"])
		selectedAttemptID := selectedByGroup[groupID]
		if groupID == "" || attemptID == "" || selectedAttemptID == "" || attemptID == selectedAttemptID {
			visible = append(visible, message)
		}
	}
	return visible
}

func responseAttemptVersionInfo(message map[string]any, messages []map[string]any) (tuiResponseAttemptVersionInfo, bool) {
	if len(messages) == 0 || !canCarryResponseAttemptVersionInfo(message) {
		return tuiResponseAttemptVersionInfo{}, false
	}
	groupID := asString(message["responseGroupID"])
	attemptID := asString(message["responseAttemptID"])
	if groupID == "" || attemptID == "" {
		return tuiResponseAttemptVersionInfo{}, false
	}

	attempts := orderedResponseAttemptIDs(groupID, messages)
	currentIndex := stringIndex(attempts, attemptID)
	if len(attempts) <= 1 || currentIndex < 0 {
		return tuiResponseAttemptVersionInfo{}, false
	}

	if selectedAttemptID := selectedResponseAttemptIDsByGroup(messages)[groupID]; selectedAttemptID != "" && selectedAttemptID != attemptID {
		return tuiResponseAttemptVersionInfo{}, false
	}

	messageID := asString(message["id"])
	lastCarrierID := ""
	for _, candidate := range messages {
		if asString(candidate["responseGroupID"]) == groupID &&
			asString(candidate["responseAttemptID"]) == attemptID &&
			canCarryResponseAttemptVersionInfo(candidate) {
			lastCarrierID = asString(candidate["id"])
		}
	}
	if lastCarrierID == "" || lastCarrierID != messageID {
		return tuiResponseAttemptVersionInfo{}, false
	}

	return tuiResponseAttemptVersionInfo{
		groupID:          groupID,
		currentAttemptID: attemptID,
		currentIndex:     currentIndex,
		totalCount:       len(attempts),
	}, true
}

func selectResponseAttempt(attemptID, groupID string, messages []map[string]any) []map[string]any {
	updated := cloneSessionMessages(messages)
	for _, message := range updated {
		shouldStoreSelection := (asString(message["id"]) == groupID && messageRole(message) == "user") ||
			asString(message["responseGroupID"]) == groupID
		if shouldStoreSelection {
			message["selectedResponseAttemptID"] = attemptID
		}
	}
	return updated
}

func preferredResponseAttemptCarrierID(messages []map[string]any, groupID, attemptID string) string {
	for index := len(messages) - 1; index >= 0; index-- {
		message := messages[index]
		if asString(message["responseGroupID"]) == groupID &&
			asString(message["responseAttemptID"]) == attemptID &&
			canCarryResponseAttemptVersionInfo(message) {
			return asString(message["id"])
		}
	}
	return ""
}

func orderedResponseAttemptIDs(groupID string, messages []map[string]any) []string {
	orderByID := map[string]tuiResponseAttemptOrder{}
	for position, message := range messages {
		if asString(message["responseGroupID"]) != groupID {
			continue
		}
		attemptID := asString(message["responseAttemptID"])
		if attemptID == "" {
			continue
		}
		recordResponseAttemptOrder(attemptID, sessionOptionalInt(message["responseAttemptIndex"]), position, orderByID)
	}
	return orderedResponseAttemptIDsFromOrder(orderByID)
}

func selectedResponseAttemptIDsByGroup(messages []map[string]any) map[string]string {
	anchorSelectionByGroup := map[string]string{}
	storedSelectionByGroup := map[string]string{}
	orderByGroup := map[string]map[string]tuiResponseAttemptOrder{}

	for position, message := range messages {
		if messageRole(message) == "user" {
			if selectedAttemptID := asString(message["selectedResponseAttemptID"]); selectedAttemptID != "" {
				anchorSelectionByGroup[asString(message["id"])] = selectedAttemptID
			}
		}

		groupID := asString(message["responseGroupID"])
		if groupID == "" {
			continue
		}
		if messageRole(message) == "assistant" || messageRole(message) == "error" {
			if selectedAttemptID := asString(message["selectedResponseAttemptID"]); selectedAttemptID != "" {
				storedSelectionByGroup[groupID] = selectedAttemptID
			}
		}

		attemptID := asString(message["responseAttemptID"])
		if attemptID == "" {
			continue
		}
		orderByID := orderByGroup[groupID]
		if orderByID == nil {
			orderByID = map[string]tuiResponseAttemptOrder{}
		}
		recordResponseAttemptOrder(attemptID, sessionOptionalInt(message["responseAttemptIndex"]), position, orderByID)
		orderByGroup[groupID] = orderByID
	}

	selectedByGroup := map[string]string{}
	for groupID, attemptID := range anchorSelectionByGroup {
		selectedByGroup[groupID] = attemptID
	}
	for groupID, attemptID := range storedSelectionByGroup {
		selectedByGroup[groupID] = attemptID
	}

	for groupID, orderByID := range orderByGroup {
		attempts := orderedResponseAttemptIDsFromOrder(orderByID)
		if len(attempts) == 0 {
			continue
		}
		selectedAttemptID := selectedByGroup[groupID]
		if selectedAttemptID != "" && stringIndex(attempts, selectedAttemptID) >= 0 {
			continue
		}
		selectedByGroup[groupID] = attempts[len(attempts)-1]
	}
	return selectedByGroup
}

func recordResponseAttemptOrder(attemptID string, explicitIndex *int, position int, orderByID map[string]tuiResponseAttemptOrder) {
	normalizedIndex := maxGoInt()
	if explicitIndex != nil {
		normalizedIndex = *explicitIndex
	}
	if existing, ok := orderByID[attemptID]; ok {
		orderByID[attemptID] = tuiResponseAttemptOrder{
			id:            attemptID,
			explicitIndex: minInt(existing.explicitIndex, normalizedIndex),
			firstPosition: minInt(existing.firstPosition, position),
		}
		return
	}
	orderByID[attemptID] = tuiResponseAttemptOrder{
		id:            attemptID,
		explicitIndex: normalizedIndex,
		firstPosition: position,
	}
}

func orderedResponseAttemptIDsFromOrder(orderByID map[string]tuiResponseAttemptOrder) []string {
	orders := make([]tuiResponseAttemptOrder, 0, len(orderByID))
	for _, order := range orderByID {
		orders = append(orders, order)
	}
	sort.Slice(orders, func(i, j int) bool {
		if orders[i].explicitIndex != orders[j].explicitIndex {
			return orders[i].explicitIndex < orders[j].explicitIndex
		}
		return orders[i].firstPosition < orders[j].firstPosition
	})
	attempts := make([]string, 0, len(orders))
	for _, order := range orders {
		attempts = append(attempts, order.id)
	}
	return attempts
}

func canCarryResponseAttemptVersionInfo(message map[string]any) bool {
	switch messageRole(message) {
	case "assistant", "tool", "system", "error":
		return true
	default:
		return false
	}
}

func sessionOptionalInt(value any) *int {
	switch value.(type) {
	case nil:
		return nil
	}
	result := asInt(value)
	return &result
}

func stringIndex(values []string, value string) int {
	for index, candidate := range values {
		if candidate == value {
			return index
		}
	}
	return -1
}

func maxGoInt() int {
	return int(^uint(0) >> 1)
}

func sessionContentVersions(message map[string]any) []string {
	switch content := message["content"].(type) {
	case string:
		return []string{content}
	case []string:
		return append([]string(nil), content...)
	case []any:
		versions := make([]string, 0, len(content))
		for _, item := range content {
			versions = append(versions, sessionContentValueString(item))
		}
		return versions
	default:
		text := sessionContentValueString(content)
		if text == "" {
			return nil
		}
		return []string{text}
	}
}

func sessionContentValueString(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case map[string]any:
		for _, key := range []string{"content", "text", "value"} {
			if text, ok := typed[key].(string); ok {
				return text
			}
		}
		return prettyJSON(typed)
	default:
		return asString(value)
	}
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
		{"cacheWriteTokens", "缓存写入"},
		{"cacheReadTokens", "缓存命中"},
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

func lineCount(value string) int {
	return strings.Count(value, "\n") + 1
}

func sessionBubbleInnerWidth(value string, maxWidth int) int {
	maxLineWidth := 0
	for _, line := range strings.Split(value, "\n") {
		maxLineWidth = maxInt(maxLineWidth, lipgloss.Width(line))
	}
	return maxInt(18, minInt(maxWidth, maxLineWidth+2))
}

func rightAlignMultiline(value string, width int) string {
	lines := strings.Split(value, "\n")
	for index, line := range lines {
		padding := maxInt(0, width-lipgloss.Width(line))
		lines[index] = strings.Repeat(" ", padding) + line
	}
	return strings.Join(lines, "\n")
}
