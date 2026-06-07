package main

import (
	"bytes"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"
)

func TestTUIEscReturnsToNavigationWithoutQuit(t *testing.T) {
	model := newTUIModel(NewDebugServer("127.0.0.1", 7654), "127.0.0.1")
	model.focus = tuiFocusContent

	updated, cmd := model.Update(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd != nil {
		if _, ok := cmd().(tea.QuitMsg); ok {
			t.Fatal("Esc 触发了 tea.Quit，期望只返回侧栏或取消输入")
		}
	}

	got, ok := updated.(tuiModel)
	if !ok {
		t.Fatalf("Update 返回类型 = %T, want tuiModel", updated)
	}
	if got.focus != tuiFocusNav {
		t.Fatalf("focus = %v, want tuiFocusNav", got.focus)
	}
}

func TestTUICtrlCQuits(t *testing.T) {
	model := newTUIModel(NewDebugServer("127.0.0.1", 7654), "127.0.0.1")

	_, cmd := model.Update(tea.KeyMsg{Type: tea.KeyCtrlC})
	if cmd == nil {
		t.Fatal("Ctrl+C 未返回退出命令")
	}
	msg := cmd()
	if _, ok := msg.(tea.QuitMsg); !ok {
		t.Fatalf("Ctrl+C 返回命令消息 = %T, want tea.QuitMsg", msg)
	}
}

func TestTUINavigationHidesOpenAICapture(t *testing.T) {
	model := newTUIModel(NewDebugServer("127.0.0.1", 7654), "127.0.0.1")
	items := model.nav.Items()
	if len(items) != tuiViewCount {
		t.Fatalf("导航项数量 = %d, want %d", len(items), tuiViewCount)
	}

	for _, item := range items {
		nav, ok := item.(navItem)
		if !ok {
			t.Fatalf("导航项类型 = %T, want navItem", item)
		}
		if nav.Title() == "捕获" || strings.Contains(nav.Description(), "OpenAI 捕获") {
			t.Fatalf("TUI 侧栏仍显示 OpenAI 捕获入口: %#v", nav)
		}
	}

	for range items {
		model.nextView()
	}
	if model.active != tuiDashboard {
		t.Fatalf("Tab 循环后 active = %v, want tuiDashboard", model.active)
	}
}

func TestTUIFormErrorResultIgnoresUserAbort(t *testing.T) {
	result := tuiFormErrorResult(huh.ErrUserAborted)
	if result.err != nil {
		t.Fatalf("用户取消表单后 err = %v, want nil", result.err)
	}
	if result.op != "noop" {
		t.Fatalf("op = %q, want noop", result.op)
	}
	if !result.clearScreen {
		t.Fatal("用户取消表单后未请求清屏，容易留下输入框残影")
	}
}

func TestNewTUIFormHidesDefaultHelp(t *testing.T) {
	value := "SELECT 1"
	form := newTUIForm(huh.NewGroup(huh.NewText().Title("SQL").Value(&value)))
	_ = form.Init()
	_, _ = form.Update(tea.WindowSizeMsg{Width: 80, Height: 24})

	view := form.View()
	if strings.Contains(view, "alt+enter") || strings.Contains(view, "open editor") || strings.Contains(view, "enter submit") {
		t.Fatalf("表单渲染了 huh 默认英文帮助，容易和 TUI 底部提示重叠: %q", view)
	}
}

func TestTUIBlockingCommandPassesTerminalIOToFormRunner(t *testing.T) {
	input := strings.NewReader("")
	var output bytes.Buffer
	var stderr bytes.Buffer
	command := &tuiBlockingCommand{
		run: func(forms tuiFormRunner) tea.Msg {
			if forms.stdin != input {
				t.Fatalf("stdin 未传给表单运行器")
			}
			if forms.stdout != &output {
				t.Fatalf("stdout 未传给表单运行器")
			}
			if forms.stderr != &stderr {
				t.Fatalf("stderr 未传给表单运行器")
			}
			return tuiCommandResultMsg{op: "noop"}
		},
	}

	command.SetStdin(input)
	command.SetStdout(&output)
	command.SetStderr(&stderr)

	if err := command.Run(); err != nil {
		t.Fatalf("Run 返回错误: %v", err)
	}
	if result, ok := command.msg.(tuiCommandResultMsg); !ok || result.op != "noop" {
		t.Fatalf("msg = %#v, want noop result", command.msg)
	}
}

func TestApplyFilesKeepsDirectoryMetadataForNavigation(t *testing.T) {
	model := newTUIModel(NewDebugServer("127.0.0.1", 7654), "127.0.0.1")
	model.applyFiles(map[string]any{
		"items": []any{
			map[string]any{"name": "Nested", "type": "directory", "size": 4096, "modificationDate": 0},
			map[string]any{"name": "note.txt", "isDirectory": false, "size": 12, "modificationDate": 0},
		},
	})

	rows := model.filesTable.Rows()
	if len(rows) != 2 {
		t.Fatalf("文件行数 = %d, want 2", len(rows))
	}
	if rows[0][1] != "目录" || rows[0][2] != "-" {
		t.Fatalf("目录行 = %#v, want 类型目录且大小为 -", rows[0])
	}
	if !fileItemIsDirectory(model.selectedFileItem()) {
		t.Fatal("选中的原始文件项没有被识别为目录，Enter 会无法进入二级文件夹")
	}
}

func TestApplySessionsUsesInfoColumn(t *testing.T) {
	model := newTUIModel(NewDebugServer("127.0.0.1", 7654), "127.0.0.1")
	model.applySessions(map[string]any{
		"sessions": []any{
			map[string]any{
				"id":                               "session-1",
				"name":                             "会话一",
				"topicPrompt":                      "主题提示",
				"enhancedPrompt":                   "增强提示",
				"lorebookIDs":                      []any{"lorebook-1", "lorebook-2"},
				"tagIDs":                           []any{"tag-1"},
				"worldbookContextIsolationEnabled": true,
			},
			map[string]any{"id": "session-2", "name": "会话二"},
		},
	})

	rows := model.sessions.Rows()
	if len(rows) != 2 {
		t.Fatalf("会话行数 = %d, want 2", len(rows))
	}
	if rows[0][2] != "主题 / 增强 / 世界书2 / 标签1 / 隔离" {
		t.Fatalf("信息列 = %q, want 元数据摘要", rows[0][2])
	}
	if rows[1][2] != "" {
		t.Fatalf("空元数据会话信息列 = %q, want empty", rows[1][2])
	}
	if model.sessionMode != tuiSessionModeList {
		t.Fatalf("sessionMode = %v, want tuiSessionModeList", model.sessionMode)
	}
}

func TestSessionDetailRendersBubblesAndMessageDetail(t *testing.T) {
	model := newTUIModel(NewDebugServer("127.0.0.1", 7654), "127.0.0.1")
	model.active = tuiSessions
	model.focus = tuiFocusContent
	model.content.Width = 100
	model.applySessionDetail(map[string]any{
		"session": map[string]any{"id": "session-1", "name": "测试会话"},
		"messages": []any{
			map[string]any{"id": "message-1", "role": "user", "content": "你好"},
			map[string]any{"id": "message-2", "role": "assistant", "content": "你好呀", "reasoningContent": "我在思考"},
		},
	})

	view := model.renderSessionsView()
	if !strings.Contains(view, "用户 #1") || !strings.Contains(view, "助手 #2") {
		t.Fatalf("气泡视图缺少角色标题: %q", view)
	}
	if strings.Contains(view, `"messages"`) || strings.Contains(view, `"session"`) {
		t.Fatalf("气泡视图不应渲染 JSON: %q", view)
	}

	model.selectNextSessionMessage()
	if model.selectedSessionMessage != 1 {
		t.Fatalf("selectedSessionMessage = %d, want 1", model.selectedSessionMessage)
	}
	_ = model.enterSelected()
	if model.sessionMode != tuiSessionModeMessageDetail {
		t.Fatalf("Enter 后 sessionMode = %v, want tuiSessionModeMessageDetail", model.sessionMode)
	}
	detail := model.renderSessionsView()
	if !strings.Contains(detail, "消息详情") || !strings.Contains(detail, "你好呀") || !strings.Contains(detail, "思考内容") || !strings.Contains(detail, "我在思考") {
		t.Fatalf("消息详情渲染异常: %q", detail)
	}
}

func TestSessionMessageUsesCurrentContentVersion(t *testing.T) {
	message := map[string]any{
		"id":                  "message-1",
		"role":                "assistant",
		"content":             []any{"旧版本正文", map[string]any{"content": "当前版本正文"}, "新版本正文"},
		"currentVersionIndex": 1,
	}

	if got := sessionMessageFullContent(message); got != "当前版本正文" {
		t.Fatalf("当前正文 = %q, want 当前版本正文", got)
	}

	model := newTUIModel(NewDebugServer("127.0.0.1", 7654), "127.0.0.1")
	model.content.Width = 100
	bubble := model.renderSessionMessageBubble(message, 0, true)
	if strings.Contains(bubble, "旧版本正文") || strings.Contains(bubble, "新版本正文") {
		t.Fatalf("气泡显示了非当前版本: %q", bubble)
	}
	if !strings.Contains(bubble, "版本 2/3") {
		t.Fatalf("多版本气泡缺少当前版本标记: %q", bubble)
	}
}

func TestSessionDetailCanSwitchContentVersion(t *testing.T) {
	model := newTUIModel(NewDebugServer("127.0.0.1", 7654), "127.0.0.1")
	model.active = tuiSessions
	model.focus = tuiFocusContent
	model.sessionMode = tuiSessionModeMessageDetail
	model.activeSession = map[string]any{"id": "3B816F4F-1BD5-4C87-B7AD-3AE39AF0E72D", "name": "版本测试"}
	model.sessionMessages = []map[string]any{
		{
			"id":                  "message-1",
			"role":                "assistant",
			"content":             []any{"版本一", "版本二"},
			"currentVersionIndex": 0,
		},
	}

	cmd := model.handleContentKey("l")
	if cmd == nil {
		t.Fatal("切换版本未返回保存命令")
	}
	if got := asInt(model.sessionMessages[0]["currentVersionIndex"]); got != 1 {
		t.Fatalf("currentVersionIndex = %d, want 1", got)
	}
	if got := sessionMessageFullContent(model.sessionMessages[0]); got != "版本二" {
		t.Fatalf("切换后的正文 = %q, want 版本二", got)
	}
}

func TestSessionUserBubbleIndentIsStable(t *testing.T) {
	model := newTUIModel(NewDebugServer("127.0.0.1", 7654), "127.0.0.1")
	model.content.Width = 100

	bubble := model.renderSessionMessageBubble(
		map[string]any{"id": "message-1", "role": "user", "content": "第一行\n第二行"},
		0,
		true,
	)
	lines := strings.Split(bubble, "\n")
	if len(lines) < 3 {
		t.Fatalf("气泡行数 = %d, want >= 3: %q", len(lines), bubble)
	}
	want := leadingSpaces(lines[0])
	for index, line := range lines[1:] {
		if got := leadingSpaces(line); got != want {
			t.Fatalf("第 %d 行缩进 = %d, want %d，气泡可能被按行错位渲染: %q", index+2, got, want, bubble)
		}
		if width := lipgloss.Width(line); width > model.content.Width-2 {
			t.Fatalf("第 %d 行宽度 = %d, want <= %d，气泡可能触发终端自动换行: %q", index+2, width, model.content.Width-2, bubble)
		}
	}
}

func TestSessionKeyboardSelectionScrollsToRenderedBubble(t *testing.T) {
	model := newTUIModel(NewDebugServer("127.0.0.1", 7654), "127.0.0.1")
	model.active = tuiSessions
	model.focus = tuiFocusContent
	model.content.Width = 100
	model.content.Height = 12

	messages := make([]any, 0, 60)
	for index := 0; index < 60; index++ {
		role := "assistant"
		if index%2 == 1 {
			role = "user"
		}
		messages = append(messages, map[string]any{
			"id":      "message",
			"role":    role,
			"content": "第一行\n第二行\n第三行\n第四行\n第五行\n第六行",
		})
	}
	model.applySessionDetail(map[string]any{
		"session":  map[string]any{"id": "session-1", "name": "滚动测试"},
		"messages": messages,
	})
	model.syncContentViewport()

	for index := 0; index < 49; index++ {
		model.selectNextSessionMessage()
	}
	model.content.SetYOffset(0)

	updated, _ := model.Update(tea.KeyMsg{Type: tea.KeyDown})
	got := updated.(tuiModel)
	if got.selectedSessionMessage != 50 {
		t.Fatalf("selectedSessionMessage = %d, want 50", got.selectedSessionMessage)
	}

	start, end, _, ok := got.selectedSessionMessageLineRange()
	if !ok {
		t.Fatal("未能计算选中气泡的行范围")
	}
	if got.content.YOffset > start || got.content.YOffset+got.content.Height-1 < end {
		t.Fatalf("选中气泡未随键盘移动进入视口: offset=%d height=%d selected=%d..%d", got.content.YOffset, got.content.Height, start, end)
	}
}

func TestSessionDetailSelectionScrollsToSection(t *testing.T) {
	model := newTUIModel(NewDebugServer("127.0.0.1", 7654), "127.0.0.1")
	model.active = tuiSessions
	model.focus = tuiFocusContent
	model.sessionMode = tuiSessionModeMessageDetail
	model.content.Width = 100
	model.content.Height = 8
	model.activeSession = map[string]any{"id": "session-1", "name": "详情滚动"}
	model.sessionMessages = []map[string]any{
		{
			"id":               "message-1",
			"role":             "assistant",
			"content":          strings.Repeat("正文很多\n", 16),
			"reasoningContent": strings.Repeat("思考很多\n", 16),
		},
	}

	model.selectNextSessionDetail()
	if model.selectedSessionDetail != 1 {
		t.Fatalf("selectedSessionDetail = %d, want 1", model.selectedSessionDetail)
	}
	start, end, _, ok := model.selectedSessionDetailLineRange()
	if !ok {
		t.Fatal("未能计算选中详情区块的行范围")
	}
	if model.content.YOffset > start || (model.content.YOffset+model.content.Height-1 < end && end-start+1 <= model.content.Height) {
		t.Fatalf("选中详情区块未进入视口: offset=%d height=%d selected=%d..%d", model.content.YOffset, model.content.Height, start, end)
	}
}

func TestSessionDetailCanSelectInfoSectionAndShowsCacheTokens(t *testing.T) {
	model := newTUIModel(NewDebugServer("127.0.0.1", 7654), "127.0.0.1")
	model.active = tuiSessions
	model.focus = tuiFocusContent
	model.sessionMode = tuiSessionModeMessageDetail
	model.content.Width = 100
	model.content.Height = 8
	model.activeSession = map[string]any{"id": "session-1", "name": "附加信息"}
	model.sessionMessages = []map[string]any{
		{
			"id":      "message-1",
			"role":    "assistant",
			"content": "正文",
			"tokenUsage": map[string]any{
				"promptTokens":     10,
				"completionTokens": 20,
				"thinkingTokens":   3,
				"cacheWriteTokens": 4,
				"cacheReadTokens":  5,
				"totalTokens":      30,
			},
		},
	}

	model.selectNextSessionDetail()
	model.selectNextSessionDetail()
	if model.selectedSessionDetail != 2 {
		t.Fatalf("selectedSessionDetail = %d, want 附加信息索引 2", model.selectedSessionDetail)
	}
	start, end, _, ok := model.selectedSessionDetailLineRange()
	if !ok || end < start {
		t.Fatalf("附加信息区块未参与选择范围计算: start=%d end=%d ok=%v", start, end, ok)
	}
	view := model.renderSessionsView()
	if !strings.Contains(view, "▶ 附加信息") {
		t.Fatalf("附加信息没有被高亮选中: %q", view)
	}
	if !strings.Contains(view, "缓存写入 4") || !strings.Contains(view, "缓存命中 5") {
		t.Fatalf("Token 摘要缺少缓存 Token: %q", view)
	}
}

func TestUpdateSessionMessageDetailPreservesCurrentContentVersion(t *testing.T) {
	message := map[string]any{
		"content":             []any{"旧版本", "当前版本", "新版本"},
		"currentVersionIndex": 1,
		"reasoningContent":    "旧思考",
	}

	updateSessionMessageDetail(message, tuiSessionDetailContent, "改后的当前版本")
	versions := asAnySlice(message["content"])
	if got := asString(versions[1]); got != "改后的当前版本" {
		t.Fatalf("当前正文版本 = %q, want 改后的当前版本", got)
	}
	if got := asString(versions[0]); got != "旧版本" {
		t.Fatalf("非当前正文版本被修改 = %q", got)
	}

	updateSessionMessageDetail(message, tuiSessionDetailReasoning, "")
	if _, ok := message["reasoningContent"]; ok {
		t.Fatal("清空思考内容后 reasoningContent 应被移除")
	}
}

func TestSessionEscReturnsOneLevelAtATime(t *testing.T) {
	model := newTUIModel(NewDebugServer("127.0.0.1", 7654), "127.0.0.1")
	model.active = tuiSessions
	model.focus = tuiFocusContent
	model.sessionMode = tuiSessionModeMessageDetail

	updated, _ := model.Update(tea.KeyMsg{Type: tea.KeyEsc})
	got := updated.(tuiModel)
	if got.sessionMode != tuiSessionModeMessages || got.focus != tuiFocusContent {
		t.Fatalf("第一次 Esc 后 mode/focus = %v/%v, want messages/content", got.sessionMode, got.focus)
	}

	updated, _ = got.Update(tea.KeyMsg{Type: tea.KeyEsc})
	got = updated.(tuiModel)
	if got.sessionMode != tuiSessionModeList || got.focus != tuiFocusContent {
		t.Fatalf("第二次 Esc 后 mode/focus = %v/%v, want list/content", got.sessionMode, got.focus)
	}

	updated, _ = got.Update(tea.KeyMsg{Type: tea.KeyEsc})
	got = updated.(tuiModel)
	if got.focus != tuiFocusNav {
		t.Fatalf("第三次 Esc 后 focus = %v, want tuiFocusNav", got.focus)
	}
}

func leadingSpaces(value string) int {
	count := 0
	for _, r := range value {
		if r != ' ' {
			return count
		}
		count++
	}
	return count
}

func TestBuildProviderUpsertPayloadIncludesHeaderOverrides(t *testing.T) {
	payload, err := buildProviderUpsertPayload(providerUpsertInput{
		ProviderID:      " provider-1 ",
		Name:            " 示例 Provider ",
		BaseURL:         " https://api.example.com/v1 ",
		APIFormat:       " openai-compatible ",
		APIKey:          "sk-test",
		HeaderOverrides: `{"X-Test":"on"}`,
		ProxyMode:       "enabled",
		ProxyType:       "socks5",
		ProxyHost:       "127.0.0.1",
		ProxyPort:       "1080",
		ProxyUsername:   "eric",
		ProxyPassword:   "secret",
	})
	if err != nil {
		t.Fatalf("buildProviderUpsertPayload 返回错误: %v", err)
	}

	if payload["command"] != "provider_upsert" {
		t.Fatalf("command = %v, want provider_upsert", payload["command"])
	}
	if payload["provider_id"] != "provider-1" {
		t.Fatalf("provider_id = %v, want provider-1", payload["provider_id"])
	}
	if payload["name"] != "示例 Provider" {
		t.Fatalf("name = %v, want 示例 Provider", payload["name"])
	}
	if payload["base_url"] != "https://api.example.com/v1" {
		t.Fatalf("base_url = %v, want https://api.example.com/v1", payload["base_url"])
	}
	if payload["api_format"] != "openai-compatible" {
		t.Fatalf("api_format = %v, want openai-compatible", payload["api_format"])
	}
	if payload["api_key"] != "sk-test" {
		t.Fatalf("api_key = %v, want sk-test", payload["api_key"])
	}

	headers, ok := payload["header_overrides"].(map[string]string)
	if !ok {
		t.Fatalf("header_overrides 类型 = %T, want map[string]string", payload["header_overrides"])
	}
	if headers["X-Test"] != "on" {
		t.Fatalf("X-Test = %v, want on", headers["X-Test"])
	}

	proxy, ok := payload["proxy_configuration"].(map[string]any)
	if !ok {
		t.Fatalf("proxy_configuration 类型 = %T, want map[string]any", payload["proxy_configuration"])
	}
	if proxy["isEnabled"] != true {
		t.Fatalf("isEnabled = %v, want true", proxy["isEnabled"])
	}
	if proxy["type"] != "socks5" {
		t.Fatalf("type = %v, want socks5", proxy["type"])
	}
	if proxy["host"] != "127.0.0.1" {
		t.Fatalf("host = %v, want 127.0.0.1", proxy["host"])
	}
	if proxy["port"] != 1080 {
		t.Fatalf("port = %v, want 1080", proxy["port"])
	}
}

func TestBuildProviderUpsertPayloadRejectsNonStringHeaders(t *testing.T) {
	if _, err := buildProviderUpsertPayload(providerUpsertInput{
		Name:            "Provider",
		APIFormat:       "openai-compatible",
		HeaderOverrides: `{"X-Test":1}`,
	}); err == nil {
		t.Fatal("err = nil，期望拒绝非字符串 Header Overrides")
	}
}

func TestBuildProviderUpsertPayloadUsesNilProxyForGlobalInheritance(t *testing.T) {
	payload, err := buildProviderUpsertPayload(providerUpsertInput{
		Name:            "Provider",
		APIFormat:       "openai-compatible",
		HeaderOverrides: "{}",
		ProxyMode:       "inherit",
	})
	if err != nil {
		t.Fatalf("buildProviderUpsertPayload 返回错误: %v", err)
	}
	if payload["proxy_configuration"] != nil {
		t.Fatalf("proxy_configuration = %v, want nil", payload["proxy_configuration"])
	}
}

func TestBuildProviderUpsertPayloadRejectsEnabledProxyWithoutHost(t *testing.T) {
	if _, err := buildProviderUpsertPayload(providerUpsertInput{
		Name:            "Provider",
		APIFormat:       "openai-compatible",
		HeaderOverrides: "{}",
		ProxyMode:       "enabled",
	}); err == nil {
		t.Fatal("err = nil，期望拒绝未填写主机的启用代理")
	}
}

func TestBuildProviderModelUpsertPayloadForExistingModel(t *testing.T) {
	payload, err := buildProviderModelUpsertPayload(providerModelUpsertInput{
		ProviderID:              " provider-1 ",
		ModelID:                 " model-1 ",
		ModelName:               " gpt-test ",
		DisplayName:             " GPT Test ",
		Kind:                    " chat ",
		InputModalities:         "text, image",
		OutputModalities:        "text",
		Capabilities:            "toolCalling, reasoning",
		RequestBodyOverrideMode: "rawJSON",
		RawRequestBodyJSON:      `{"model":"gpt-test"}`,
		RequestBodyControls:     `[{"id":"thinking","title":"Thinking","kind":"toggle","isEnabled":true,"defaultIsActive":false,"payload":{"reasoning_effort":"high"},"options":[]}]`,
		OverrideParameters:      `{"temperature":0.2}`,
		Pricing:                 `{"inputPerMillionTokens":1.5}`,
		IsActivated:             false,
	})
	if err != nil {
		t.Fatalf("buildProviderModelUpsertPayload 返回错误: %v", err)
	}

	if payload["command"] != "provider_model_upsert" {
		t.Fatalf("command = %v, want provider_model_upsert", payload["command"])
	}
	if payload["provider_id"] != "provider-1" {
		t.Fatalf("provider_id = %v, want provider-1", payload["provider_id"])
	}
	if payload["model_id"] != "model-1" {
		t.Fatalf("model_id = %v, want model-1", payload["model_id"])
	}
	if payload["model_name"] != "gpt-test" {
		t.Fatalf("model_name = %v, want gpt-test", payload["model_name"])
	}
	if payload["display_name"] != "GPT Test" {
		t.Fatalf("display_name = %v, want GPT Test", payload["display_name"])
	}
	if payload["is_activated"] != false {
		t.Fatalf("is_activated = %v, want false", payload["is_activated"])
	}
	if payload["request_body_override_mode"] != "rawJSON" {
		t.Fatalf("request_body_override_mode = %v, want rawJSON", payload["request_body_override_mode"])
	}
	if payload["raw_request_body_json"] != `{"model":"gpt-test"}` {
		t.Fatalf("raw_request_body_json = %v, want raw JSON", payload["raw_request_body_json"])
	}

	inputModalities, ok := payload["input_modalities"].([]string)
	if !ok {
		t.Fatalf("input_modalities 类型 = %T, want []string", payload["input_modalities"])
	}
	if len(inputModalities) != 2 || inputModalities[0] != "text" || inputModalities[1] != "image" {
		t.Fatalf("input_modalities = %#v, want text/image", inputModalities)
	}

	capabilities, ok := payload["capabilities"].([]string)
	if !ok {
		t.Fatalf("capabilities 类型 = %T, want []string", payload["capabilities"])
	}
	if len(capabilities) != 2 || capabilities[0] != "toolCalling" || capabilities[1] != "reasoning" {
		t.Fatalf("capabilities = %#v, want toolCalling/reasoning", capabilities)
	}

	override, ok := payload["override_parameters"].(map[string]any)
	if !ok {
		t.Fatalf("override_parameters 类型 = %T, want map[string]any", payload["override_parameters"])
	}
	if override["temperature"] != 0.2 {
		t.Fatalf("temperature = %v, want 0.2", override["temperature"])
	}

	requestBodyControls, ok := payload["request_body_controls"].([]any)
	if !ok {
		t.Fatalf("request_body_controls 类型 = %T, want []any", payload["request_body_controls"])
	}
	if len(requestBodyControls) != 1 {
		t.Fatalf("request_body_controls 长度 = %d, want 1", len(requestBodyControls))
	}
	control, ok := requestBodyControls[0].(map[string]any)
	if !ok {
		t.Fatalf("request_body_controls[0] 类型 = %T, want map[string]any", requestBodyControls[0])
	}
	if control["id"] != "thinking" {
		t.Fatalf("control id = %v, want thinking", control["id"])
	}

	pricing, ok := payload["pricing"].(map[string]any)
	if !ok {
		t.Fatalf("pricing 类型 = %T, want map[string]any", payload["pricing"])
	}
	if pricing["inputPerMillionTokens"] != 1.5 {
		t.Fatalf("inputPerMillionTokens = %v, want 1.5", pricing["inputPerMillionTokens"])
	}
}

func TestBuildProviderModelUpsertPayloadUsesEmptyRequestBodyControls(t *testing.T) {
	payload, err := buildProviderModelUpsertPayload(providerModelUpsertInput{
		ProviderID:  "provider-1",
		ModelName:   "gpt-test",
		Kind:        "chat",
		IsActivated: true,
	})
	if err != nil {
		t.Fatalf("buildProviderModelUpsertPayload 返回错误: %v", err)
	}
	controls, ok := payload["request_body_controls"].([]any)
	if !ok {
		t.Fatalf("request_body_controls 类型 = %T, want []any", payload["request_body_controls"])
	}
	if len(controls) != 0 {
		t.Fatalf("request_body_controls = %#v, want empty", controls)
	}
}

func TestBuildProviderModelUpsertPayloadRejectsNonObjectOverride(t *testing.T) {
	if _, err := buildProviderModelUpsertPayload(providerModelUpsertInput{
		ProviderID:         "provider-1",
		ModelName:          "gpt-test",
		Kind:               "chat",
		OverrideParameters: `[1,2]`,
		IsActivated:        true,
	}); err == nil {
		t.Fatal("err = nil，期望拒绝非对象 Override Parameters")
	}
}

func TestBuildProviderModelUpsertPayloadRejectsNonArrayRequestBodyControls(t *testing.T) {
	if _, err := buildProviderModelUpsertPayload(providerModelUpsertInput{
		ProviderID:          "provider-1",
		ModelName:           "gpt-test",
		Kind:                "chat",
		RequestBodyControls: `{"id":"thinking"}`,
		OverrideParameters:  "{}",
		IsActivated:         true,
	}); err == nil {
		t.Fatal("err = nil，期望拒绝非数组 Request Body Controls")
	}
}

func TestBuildProviderModelUpsertPayloadRejectsNonObjectPricing(t *testing.T) {
	if _, err := buildProviderModelUpsertPayload(providerModelUpsertInput{
		ProviderID:  "provider-1",
		ModelName:   "gpt-test",
		Kind:        "chat",
		Pricing:     `[1,2]`,
		IsActivated: true,
	}); err == nil {
		t.Fatal("err = nil，期望拒绝非对象 Pricing")
	}
}

func TestProviderModelOptionLabel(t *testing.T) {
	label := providerModelOptionLabel(map[string]any{
		"id":          "model-1",
		"modelName":   "gpt-test",
		"displayName": "GPT Test",
	}, 2)

	if label != "3. GPT Test · gpt-test" {
		t.Fatalf("label = %q, want %q", label, "3. GPT Test · gpt-test")
	}
}
