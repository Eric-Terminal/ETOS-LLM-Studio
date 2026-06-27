package main

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/table"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/huh"
)

const mcpServersListSQL = `
SELECT
    s.id,
    s.display_name,
    s.notes,
    s.is_selected_for_chat,
    s.status,
    s.transport_kind,
    COALESCE(s.endpoint_url, s.sse_endpoint_url, s.message_endpoint_url, '') AS endpoint,
    s.endpoint_url,
    s.message_endpoint_url,
    s.sse_endpoint_url,
    s.metadata_cached_at,
    s.updated_at,
    s.api_key,
    s.additional_headers_json,
    s.disabled_tool_ids_json,
    s.tool_approval_policies_json,
    s.oauth_payload_json,
    s.stream_resumption_token,
    (SELECT COUNT(*) FROM mcp_tools t WHERE t.server_id = s.id) AS tool_count,
    COALESCE((
        SELECT GROUP_CONCAT(tool_name, char(10))
        FROM (
            SELECT tool_name
            FROM mcp_tools
            WHERE server_id = s.id
            ORDER BY sort_index ASC, tool_name ASC
        )
    ), '') AS tool_names
FROM mcp_servers s
ORDER BY LOWER(s.display_name) ASC, s.id ASC
`

type mcpServerInput struct {
	ID                       string
	DisplayName              string
	Notes                    string
	TransportKind            string
	EndpointURL              string
	MessageEndpointURL       string
	SSEEndpointURL           string
	APIKey                   string
	AdditionalHeadersJSON    string
	DisabledToolIDsJSON      string
	ToolApprovalPoliciesJSON string
	OAuthPayloadJSON         string
	StreamResumptionToken    string
	IsSelectedForChat        bool
}

func (m tuiModel) loadMCPServers() tea.Cmd {
	return m.markLoading(m.remoteCommand("mcp:list", map[string]any{
		"command":    "query_sqlite",
		"database":   "config",
		"sql":        mcpServersListSQL,
		"max_rows":   500,
		"parameters": []any{},
	}, 30*time.Second))
}

func (m *tuiModel) applyMCPServers(response map[string]any) {
	rowsRaw := asMapSlice(response["rows"])
	rows := make([]table.Row, 0, len(rowsRaw))
	for _, item := range rowsRaw {
		rows = append(rows, table.Row{
			asString(item["id"]),
			asString(item["display_name"]),
			asString(item["transport_kind"]),
			boolLabel(asBool(item["is_selected_for_chat"])),
			fmt.Sprintf("%d", asInt(item["tool_count"])),
			mcpEndpointText(item),
		})
	}
	m.mcpRows = rowsRaw
	m.mcpServers.SetRows(rows)
	m.preview.SetValue(mcpListPreview(rowsRaw))
	m.setMessage(fmt.Sprintf("已加载 %d 个 MCP 服务器", len(rows)), tuiOKStyle)
}

func (m tuiModel) selectedMCPServer() map[string]any {
	row := m.mcpServers.SelectedRow()
	if len(row) == 0 {
		return nil
	}
	id := row[0]
	for _, server := range m.mcpRows {
		if asString(server["id"]) == id {
			return server
		}
	}
	return nil
}

func (m tuiModel) showSelectedMCPServer() tea.Cmd {
	server := m.selectedMCPServer()
	if len(server) == 0 {
		return nil
	}
	return tuiMessageCommand(tuiCommandResultMsg{
		op: "preview",
		response: map[string]any{
			"status":       "ok",
			"preview":      mcpServerRowPreview(server),
			"focus_detail": true,
		},
	})
}

func (m *tuiModel) addMCPServer() tea.Cmd {
	input := mcpServerInput{
		ID:                       newTUIUUID(),
		TransportKind:            "http",
		AdditionalHeadersJSON:    "{}",
		DisabledToolIDsJSON:      "[]",
		ToolApprovalPoliciesJSON: "{}",
		IsSelectedForChat:        true,
	}
	return m.promptMCPServer("新增 MCP 服务器", input, true)
}

func (m *tuiModel) editSelectedMCPServer() tea.Cmd {
	server := m.selectedMCPServer()
	if len(server) == 0 {
		return nil
	}
	input := mcpServerInputFromRow(server)
	return m.promptMCPServer("编辑 MCP 服务器", input, false)
}

func (m *tuiModel) promptMCPServer(title string, input mcpServerInput, isNew bool) tea.Cmd {
	originalInput := input
	additionalHeadersField := huh.NewText().Title("Additional Headers JSON").Value(&input.AdditionalHeadersJSON)
	oauthPayloadField := huh.NewText().Title("OAuth Payload JSON").Value(&input.OAuthPayloadJSON)
	notesField := huh.NewText().Title("备注").Value(&input.Notes)
	form := newTUIForm(huh.NewGroup(
		huh.NewInput().Title("显示名称").Value(&input.DisplayName),
		huh.NewSelect[string]().
			Title("传输类型").
			Options(tuiMCPTransportKindOptions()...).
			Value(&input.TransportKind).
			Height(3),
		huh.NewInput().Title("Streamable HTTP / OAuth Endpoint").Value(&input.EndpointURL),
		huh.NewInput().Title("SSE Endpoint").Value(&input.SSEEndpointURL),
		huh.NewInput().Title("Message Endpoint（SSE 可留空自动推断）").Value(&input.MessageEndpointURL),
		huh.NewInput().Title("Bearer API Key").EchoMode(huh.EchoModePassword).Value(&input.APIKey),
		additionalHeadersField,
		oauthPayloadField,
		notesField,
		huh.NewConfirm().Title("加入聊天路由").Affirmative("加入").Negative("不加入").Value(&input.IsSelectedForChat),
	))
	return m.beginInlineForm(title, form, func(m *tuiModel) tea.Cmd {
		resetMetadata, err := mcpShouldResetMetadata(originalInput, input, isNew)
		if err != nil {
			return tuiMessageCommand(tuiCommandResultMsg{op: "mcp:upsert", err: err})
		}
		payload, resetMetadata, err := buildMCPServerSavePayload(input, resetMetadata, isNew)
		if err != nil {
			return tuiMessageCommand(tuiCommandResultMsg{op: "mcp:upsert", err: err})
		}
		commands := []tea.Cmd{
			m.remoteCommand("mcp:upsert", payload, 45*time.Second),
		}
		if resetMetadata {
			commands = append(commands, m.remoteCommand("mcp:tools_clear", mcpDeleteToolsPayload(input.ID), 30*time.Second))
		}
		commands = append(commands, m.loadMCPServers())
		return tea.Sequence(commands...)
	}, additionalHeadersField, oauthPayloadField, notesField)
}

func (m *tuiModel) editSelectedMCPPolicies() tea.Cmd {
	server := m.selectedMCPServer()
	if len(server) == 0 {
		return nil
	}
	serverID := asString(server["id"])
	disabledToolIDs := firstNonEmpty(asString(server["disabled_tool_ids_json"]), "[]")
	policies := firstNonEmpty(asString(server["tool_approval_policies_json"]), "{}")
	disabledToolIDsField := huh.NewText().Title("Disabled Tool IDs JSON").Value(&disabledToolIDs)
	policiesField := huh.NewText().Title("Tool Approval Policies JSON").Value(&policies)
	form := newTUIForm(huh.NewGroup(
		disabledToolIDsField,
		policiesField,
	))
	return m.beginInlineForm("编辑 MCP 工具策略", form, func(m *tuiModel) tea.Cmd {
		normalizedDisabled, err := normalizeJSONStringArray(disabledToolIDs, "Disabled Tool IDs")
		if err != nil {
			return tuiMessageCommand(tuiCommandResultMsg{op: "mcp:policies", err: err})
		}
		normalizedPolicies, err := normalizeMCPApprovalPoliciesJSON(policies)
		if err != nil {
			return tuiMessageCommand(tuiCommandResultMsg{op: "mcp:policies", err: err})
		}
		payload := mcpUpdatePoliciesPayload(serverID, normalizedDisabled, normalizedPolicies)
		return tea.Sequence(
			m.remoteCommand("mcp:policies", payload, 30*time.Second),
			m.loadMCPServers(),
		)
	}, disabledToolIDsField, policiesField)
}

func (m *tuiModel) editSelectedMCPToolPolicy() tea.Cmd {
	server := m.selectedMCPServer()
	if len(server) == 0 {
		return nil
	}
	toolNames := mcpToolNamesFromRow(server)
	if len(toolNames) == 0 {
		return tuiMessageCommand(tuiCommandResultMsg{
			op:  "mcp:tool_policy",
			err: fmt.Errorf("当前 MCP 服务器还没有缓存工具；请先在 Swift 端连接或刷新元数据"),
		})
	}

	serverID := asString(server["id"])
	toolID := toolNames[0]
	selectOptions := make([]huh.Option[string], 0, len(toolNames))
	for _, name := range toolNames {
		selectOptions = append(selectOptions, huh.NewOption(name, name))
	}
	selectForm := newTUIForm(huh.NewGroup(
		huh.NewSelect[string]().
			Title("选择工具").
			Options(selectOptions...).
			Value(&toolID).
			Height(maxInt(4, minInt(len(selectOptions), 12))),
	))
	return m.beginInlineForm("选择 MCP 工具", selectForm, func(m *tuiModel) tea.Cmd {
		enabled := true
		policy := "ask_every_time"
		disabledSet, err := parseMCPStringSetJSON(asString(server["disabled_tool_ids_json"]), "Disabled Tool IDs")
		if err != nil {
			return tuiMessageCommand(tuiCommandResultMsg{op: "mcp:tool_policy", err: err})
		}
		policies, err := parseMCPApprovalPoliciesJSON(asString(server["tool_approval_policies_json"]))
		if err != nil {
			return tuiMessageCommand(tuiCommandResultMsg{op: "mcp:tool_policy", err: err})
		}
		enabled = !disabledSet[toolID]
		if value := policies[toolID]; value != "" {
			policy = value
		}

		editForm := newTUIForm(huh.NewGroup(
			huh.NewConfirm().
				Title("启用工具 "+toolID).
				Affirmative("启用").
				Negative("禁用").
				Value(&enabled),
			huh.NewSelect[string]().
				Title("审批策略").
				Options(tuiMCPApprovalPolicyOptions()...).
				Value(&policy).
				Height(3),
		))
		return m.beginInlineForm("编辑 MCP 工具策略", editForm, func(m *tuiModel) tea.Cmd {
			disabledJSON, policiesJSON, err := updateMCPToolPolicyJSON(
				asString(server["disabled_tool_ids_json"]),
				asString(server["tool_approval_policies_json"]),
				toolID,
				enabled,
				policy,
			)
			if err != nil {
				return tuiMessageCommand(tuiCommandResultMsg{op: "mcp:tool_policy", err: err})
			}
			payload := mcpUpdatePoliciesPayload(serverID, disabledJSON, policiesJSON)
			return tea.Sequence(
				m.remoteCommand("mcp:tool_policy", payload, 30*time.Second),
				m.loadMCPServers(),
			)
		})
	})
}

func (m *tuiModel) toggleSelectedMCPServerChat() tea.Cmd {
	server := m.selectedMCPServer()
	if len(server) == 0 {
		return nil
	}
	enabled := !asBool(server["is_selected_for_chat"])
	payload := mcpToggleServerChatPayload(asString(server["id"]), enabled)
	return tea.Sequence(
		m.markLoading(m.remoteCommand("mcp:toggle_chat", payload, 30*time.Second)),
		m.loadMCPServers(),
	)
}

func (m *tuiModel) toggleMCPGlobalChatTools() tea.Cmd {
	enabled := true
	form := newTUIForm(huh.NewGroup(
		huh.NewConfirm().
			Title("向模型暴露 MCP 工具").
			Affirmative("开启").
			Negative("关闭").
			Value(&enabled),
	))
	return m.beginInlineForm("MCP 全局开关", form, func(m *tuiModel) tea.Cmd {
		return func() tea.Msg {
			response, err := m.server.sendCommandWithResponse(map[string]any{
				"command": "app_config_set",
				"key":     "mcp.chatToolsEnabled",
				"value":   enabled,
			}, 25*time.Second)
			return tuiCommandResultMsg{op: "mcp:global_toggle", response: response, err: err}
		}
	})
}

func (m *tuiModel) deleteSelectedMCPServer() tea.Cmd {
	server := m.selectedMCPServer()
	if len(server) == 0 {
		return nil
	}
	ok := false
	form := newTUIForm(huh.NewGroup(
		huh.NewConfirm().Title("确认删除 MCP 服务器 " + asString(server["display_name"]) + "？").Value(&ok),
	))
	return m.beginInlineForm("删除 MCP 服务器", form, func(m *tuiModel) tea.Cmd {
		if !ok {
			return tuiMessageCommand(tuiCommandResultMsg{op: "noop", response: map[string]any{"status": "ok", "message": "已取消"}})
		}
		serverID := asString(server["id"])
		return tea.Sequence(
			m.remoteCommand("mcp:tools_delete", mcpDeleteToolsPayload(serverID), 30*time.Second),
			m.remoteCommand("mcp:delete", mcpDeleteServerPayload(serverID), 30*time.Second),
			m.loadMCPServers(),
		)
	})
}

func buildMCPServerUpsertPayload(input mcpServerInput, resetMetadata bool) (map[string]any, bool, error) {
	values, err := buildMCPServerMutationValues(input)
	if err != nil {
		return nil, false, err
	}

	sql := mcpUpsertSQL(resetMetadata)
	payload := map[string]any{
		"command":            "mutate_sqlite",
		"database":           "config",
		"sql":                sql,
		"parameters":         values.insertParameters(),
		"returning_max_rows": 1,
	}
	return payload, resetMetadata, nil
}

func buildMCPServerSavePayload(input mcpServerInput, resetMetadata bool, isNew bool) (map[string]any, bool, error) {
	if isNew {
		return buildMCPServerUpsertPayload(input, resetMetadata)
	}
	return buildMCPServerUpdatePayload(input, resetMetadata)
}

func buildMCPServerUpdatePayload(input mcpServerInput, resetMetadata bool) (map[string]any, bool, error) {
	values, err := buildMCPServerMutationValues(input)
	if err != nil {
		return nil, false, err
	}

	payload := map[string]any{
		"command":            "mutate_sqlite",
		"database":           "config",
		"sql":                mcpUpdateSQL(resetMetadata),
		"parameters":         values.updateParameters(),
		"returning_max_rows": 1,
	}
	return payload, resetMetadata, nil
}

type mcpServerMutationValues struct {
	input               mcpServerInput
	endpointURL         string
	messageEndpointURL  string
	sseEndpointURL      string
	apiKey              string
	headersJSON         string
	disabledToolIDsJSON string
	policiesJSON        string
	oauthPayloadJSON    string
}

func buildMCPServerMutationValues(input mcpServerInput) (mcpServerMutationValues, error) {
	input = normalizedMCPServerInput(input)

	if input.ID == "" {
		return mcpServerMutationValues{}, fmt.Errorf("MCP 服务器 ID 不能为空")
	}
	if input.DisplayName == "" {
		return mcpServerMutationValues{}, fmt.Errorf("显示名称不能为空")
	}

	endpointURL, messageEndpointURL, sseEndpointURL, err := resolveMCPTransportURLs(input)
	if err != nil {
		return mcpServerMutationValues{}, err
	}

	disabledToolIDsJSON, err := normalizeJSONStringArray(input.DisabledToolIDsJSON, "Disabled Tool IDs")
	if err != nil {
		return mcpServerMutationValues{}, err
	}
	policiesJSON, err := normalizeMCPApprovalPoliciesJSON(input.ToolApprovalPoliciesJSON)
	if err != nil {
		return mcpServerMutationValues{}, err
	}

	apiKey := input.APIKey
	headersJSON := ""
	oauthPayloadJSON := ""
	switch input.TransportKind {
	case "http", "sse":
		headersJSON, err = normalizeMCPHeadersJSON(input.AdditionalHeadersJSON)
		if err != nil {
			return mcpServerMutationValues{}, err
		}
	case "oauth":
		oauthPayloadJSON, err = normalizeMCPOAuthPayloadJSON(input.OAuthPayloadJSON)
		if err != nil {
			return mcpServerMutationValues{}, err
		}
		apiKey = ""
	}

	return mcpServerMutationValues{
		input:               input,
		endpointURL:         endpointURL,
		messageEndpointURL:  messageEndpointURL,
		sseEndpointURL:      sseEndpointURL,
		apiKey:              apiKey,
		headersJSON:         headersJSON,
		disabledToolIDsJSON: disabledToolIDsJSON,
		policiesJSON:        policiesJSON,
		oauthPayloadJSON:    oauthPayloadJSON,
	}, nil
}

func (values mcpServerMutationValues) insertParameters() []any {
	return []any{
		values.input.ID,
		values.input.DisplayName,
		nullableTrimmed(values.input.Notes),
		boolToSQLiteInt(values.input.IsSelectedForChat),
		values.input.TransportKind,
		nullableTrimmed(values.endpointURL),
		nullableTrimmed(values.messageEndpointURL),
		nullableTrimmed(values.sseEndpointURL),
		unixNowSeconds(),
		nullableTrimmed(values.apiKey),
		nullableTrimmed(values.headersJSON),
		nullableTrimmed(values.disabledToolIDsJSON),
		nullableTrimmed(values.policiesJSON),
		nullableTrimmed(values.oauthPayloadJSON),
		nullableTrimmed(values.input.StreamResumptionToken),
	}
}

func (values mcpServerMutationValues) updateParameters() []any {
	parameters := values.insertParameters()[1:]
	return append(parameters, values.input.ID)
}

func mcpShouldResetMetadata(original, updated mcpServerInput, isNew bool) (bool, error) {
	if isNew {
		return false, nil
	}
	updatedSignature, err := mcpTransportSignature(updated, true)
	if err != nil {
		return false, err
	}
	originalSignature, err := mcpTransportSignature(original, false)
	if err != nil {
		return true, nil
	}
	return originalSignature != updatedSignature, nil
}

func mcpTransportSignature(input mcpServerInput, strict bool) (string, error) {
	input = normalizedMCPServerInput(input)
	endpointURL, messageEndpointURL, sseEndpointURL, err := resolveMCPTransportURLs(input)
	if err != nil {
		return "", err
	}

	signature := []string{input.TransportKind, endpointURL, messageEndpointURL, sseEndpointURL}
	switch input.TransportKind {
	case "http", "sse":
		headersJSON, err := normalizeMCPHeadersJSON(input.AdditionalHeadersJSON)
		if err != nil {
			if strict {
				return "", err
			}
			headersJSON = ""
		}
		signature = append(signature, input.APIKey, headersJSON)
	case "oauth":
		oauthPayloadJSON, err := normalizeMCPOAuthPayloadJSON(input.OAuthPayloadJSON)
		if err != nil {
			return "", err
		}
		signature = append(signature, oauthPayloadJSON)
	}

	data, err := json.Marshal(signature)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func normalizedMCPServerInput(input mcpServerInput) mcpServerInput {
	input.ID = normalizeMCPServerID(input.ID)
	input.DisplayName = strings.TrimSpace(input.DisplayName)
	input.TransportKind = strings.TrimSpace(strings.ToLower(input.TransportKind))
	input.EndpointURL = strings.TrimSpace(input.EndpointURL)
	input.MessageEndpointURL = strings.TrimSpace(input.MessageEndpointURL)
	input.SSEEndpointURL = strings.TrimSpace(input.SSEEndpointURL)
	input.APIKey = strings.TrimSpace(input.APIKey)
	return input
}

func normalizeMCPServerID(serverID string) string {
	trimmed := strings.TrimSpace(serverID)
	if isUUIDText(trimmed) {
		return strings.ToUpper(trimmed)
	}
	return trimmed
}

func isUUIDText(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, r := range value {
		switch index {
		case 8, 13, 18, 23:
			if r != '-' {
				return false
			}
		default:
			if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')) {
				return false
			}
		}
	}
	return true
}

func mcpUpsertSQL(resetMetadata bool) string {
	resetClause := ""
	if resetMetadata {
		resetClause = `,
                status = 'idle',
                metadata_cached_at = NULL,
                info_json = NULL,
                resources_json = NULL,
                resource_templates_json = NULL,
                prompts_json = NULL,
                roots_json = NULL`
	}
	return `
INSERT INTO mcp_servers (
    id, display_name, notes, is_selected_for_chat, status, transport_kind,
    endpoint_url, message_endpoint_url, sse_endpoint_url, metadata_cached_at, updated_at,
    api_key, additional_headers_json, disabled_tool_ids_json, tool_approval_policies_json,
    oauth_payload_json, stream_resumption_token,
    info_json, resources_json, resource_templates_json, prompts_json, roots_json
) VALUES (?, ?, ?, ?, 'idle', ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL)
ON CONFLICT(id) DO UPDATE SET
    display_name = excluded.display_name,
    notes = excluded.notes,
    is_selected_for_chat = excluded.is_selected_for_chat,
    transport_kind = excluded.transport_kind,
    endpoint_url = excluded.endpoint_url,
    message_endpoint_url = excluded.message_endpoint_url,
    sse_endpoint_url = excluded.sse_endpoint_url,
    updated_at = excluded.updated_at,
    api_key = excluded.api_key,
    additional_headers_json = excluded.additional_headers_json,
    disabled_tool_ids_json = excluded.disabled_tool_ids_json,
    tool_approval_policies_json = excluded.tool_approval_policies_json,
    oauth_payload_json = excluded.oauth_payload_json,
    stream_resumption_token = excluded.stream_resumption_token` + resetClause + `
RETURNING id, display_name, transport_kind, is_selected_for_chat
`
}

func mcpUpdateSQL(resetMetadata bool) string {
	resetClause := ""
	if resetMetadata {
		resetClause = `,
    status = 'idle',
    metadata_cached_at = NULL,
    info_json = NULL,
    resources_json = NULL,
    resource_templates_json = NULL,
    prompts_json = NULL,
    roots_json = NULL`
	}
	return `
UPDATE mcp_servers
SET
    display_name = ?,
    notes = ?,
    is_selected_for_chat = ?,
    transport_kind = ?,
    endpoint_url = ?,
    message_endpoint_url = ?,
    sse_endpoint_url = ?,
    updated_at = ?,
    api_key = ?,
    additional_headers_json = ?,
    disabled_tool_ids_json = ?,
    tool_approval_policies_json = ?,
    oauth_payload_json = ?,
    stream_resumption_token = ?` + resetClause + `
WHERE id COLLATE NOCASE = ?
RETURNING id, display_name, transport_kind, is_selected_for_chat
`
}

func resolveMCPTransportURLs(input mcpServerInput) (string, string, string, error) {
	switch input.TransportKind {
	case "http":
		if err := validateHTTPURL(input.EndpointURL, "Streamable HTTP Endpoint"); err != nil {
			return "", "", "", err
		}
		return input.EndpointURL, "", "", nil
	case "sse":
		if err := validateHTTPURL(input.SSEEndpointURL, "SSE Endpoint"); err != nil {
			return "", "", "", err
		}
		messageURL := input.MessageEndpointURL
		if messageURL == "" {
			messageURL = inferMCPMessageEndpoint(input.SSEEndpointURL)
		}
		if err := validateHTTPURL(messageURL, "Message Endpoint"); err != nil {
			return "", "", "", err
		}
		return "", messageURL, input.SSEEndpointURL, nil
	case "oauth":
		if err := validateHTTPURL(input.EndpointURL, "OAuth Endpoint"); err != nil {
			return "", "", "", err
		}
		if strings.TrimSpace(input.OAuthPayloadJSON) == "" {
			return "", "", "", fmt.Errorf("OAuth 传输需要填写 OAuth Payload JSON")
		}
		return input.EndpointURL, "", "", nil
	default:
		return "", "", "", fmt.Errorf("传输类型必须是 http、sse 或 oauth")
	}
}

func validateHTTPURL(value, title string) error {
	parsed, err := url.Parse(strings.TrimSpace(value))
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return fmt.Errorf("%s 不是合法 URL", title)
	}
	if scheme := strings.ToLower(parsed.Scheme); scheme != "http" && scheme != "https" {
		return fmt.Errorf("%s 必须使用 http 或 https", title)
	}
	return nil
}

func inferMCPMessageEndpoint(sseEndpoint string) string {
	parsed, err := url.Parse(sseEndpoint)
	if err != nil {
		return sseEndpoint
	}
	parts := strings.Split(parsed.Path, "/")
	for index, part := range parts {
		if part == "sse" {
			parts[index] = "message"
			parsed.Path = strings.Join(parts, "/")
			return parsed.String()
		}
	}
	return sseEndpoint
}

func mcpToggleServerChatPayload(serverID string, enabled bool) map[string]any {
	serverID = normalizeMCPServerID(serverID)
	return map[string]any{
		"command":  "mutate_sqlite",
		"database": "config",
		"sql":      "UPDATE mcp_servers SET is_selected_for_chat = ?, updated_at = ? WHERE id COLLATE NOCASE = ? RETURNING id, display_name, is_selected_for_chat",
		"parameters": []any{
			boolToSQLiteInt(enabled),
			unixNowSeconds(),
			serverID,
		},
		"returning_max_rows": 1,
	}
}

func mcpUpdatePoliciesPayload(serverID, disabledToolIDsJSON, policiesJSON string) map[string]any {
	serverID = normalizeMCPServerID(serverID)
	return map[string]any{
		"command":  "mutate_sqlite",
		"database": "config",
		"sql":      "UPDATE mcp_servers SET disabled_tool_ids_json = ?, tool_approval_policies_json = ?, updated_at = ? WHERE id COLLATE NOCASE = ? RETURNING id, display_name",
		"parameters": []any{
			nullableTrimmed(disabledToolIDsJSON),
			nullableTrimmed(policiesJSON),
			unixNowSeconds(),
			serverID,
		},
		"returning_max_rows": 1,
	}
}

func mcpDeleteToolsPayload(serverID string) map[string]any {
	serverID = normalizeMCPServerID(serverID)
	return map[string]any{
		"command":    "mutate_sqlite",
		"database":   "config",
		"sql":        "DELETE FROM mcp_tools WHERE server_id COLLATE NOCASE = ?",
		"parameters": []any{serverID},
	}
}

func mcpDeleteServerPayload(serverID string) map[string]any {
	serverID = normalizeMCPServerID(serverID)
	return map[string]any{
		"command":    "mutate_sqlite",
		"database":   "config",
		"sql":        "DELETE FROM mcp_servers WHERE id COLLATE NOCASE = ?",
		"parameters": []any{serverID},
	}
}

func mcpServerInputFromRow(row map[string]any) mcpServerInput {
	return mcpServerInput{
		ID:                       normalizeMCPServerID(asString(row["id"])),
		DisplayName:              asString(row["display_name"]),
		Notes:                    asString(row["notes"]),
		TransportKind:            asString(row["transport_kind"]),
		EndpointURL:              asString(row["endpoint_url"]),
		MessageEndpointURL:       asString(row["message_endpoint_url"]),
		SSEEndpointURL:           asString(row["sse_endpoint_url"]),
		APIKey:                   asString(row["api_key"]),
		AdditionalHeadersJSON:    firstNonEmpty(asString(row["additional_headers_json"]), "{}"),
		DisabledToolIDsJSON:      firstNonEmpty(asString(row["disabled_tool_ids_json"]), "[]"),
		ToolApprovalPoliciesJSON: firstNonEmpty(asString(row["tool_approval_policies_json"]), "{}"),
		OAuthPayloadJSON:         asString(row["oauth_payload_json"]),
		StreamResumptionToken:    asString(row["stream_resumption_token"]),
		IsSelectedForChat:        asBool(row["is_selected_for_chat"]),
	}
}

func mcpEndpointText(row map[string]any) string {
	return truncateLine(firstNonEmpty(
		asString(row["endpoint"]),
		asString(row["endpoint_url"]),
		asString(row["sse_endpoint_url"]),
		asString(row["message_endpoint_url"]),
	), 42)
}

func mcpListPreview(rows []map[string]any) string {
	selected := 0
	ready := 0
	tools := 0
	for _, row := range rows {
		if asBool(row["is_selected_for_chat"]) {
			selected++
		}
		if asString(row["status"]) == "ready" {
			ready++
		}
		tools += asInt(row["tool_count"])
	}
	return strings.Join([]string{
		"MCP 服务器",
		fmt.Sprintf("  总数: %d", len(rows)),
		fmt.Sprintf("  已加入聊天: %d", selected),
		fmt.Sprintf("  Ready 缓存: %d", ready),
		fmt.Sprintf("  已缓存工具: %d", tools),
		"",
		"操作",
		"  a 新增服务器，e 编辑服务器，p 修改工具启用/审批策略，t 切换聊天路由。",
	}, "\n")
}

func mcpServerPreview(rows []map[string]any) string {
	if len(rows) == 0 {
		return "未找到 MCP 服务器"
	}
	return mcpServerRowPreview(rows[0])
}

func mcpServerRowPreview(row map[string]any) string {
	lines := []string{
		"MCP 服务器",
		"  ID: " + emptyDash(asString(row["id"])),
		"  名称: " + emptyDash(asString(row["display_name"])),
		"  传输: " + emptyDash(asString(row["transport_kind"])),
		"  状态: " + emptyDash(asString(row["status"])),
		"  加入聊天: " + boolLabel(asBool(row["is_selected_for_chat"])),
		"  Endpoint: " + emptyDash(mcpEndpointText(row)),
		"  API Key: " + secretPresenceLabel(asString(row["api_key"])),
		"",
		"策略",
		"  禁用工具: " + emptyDash(firstNonEmpty(asString(row["disabled_tool_ids_json"]), "[]")),
		"  审批策略: " + emptyDash(firstNonEmpty(asString(row["tool_approval_policies_json"]), "{}")),
		"",
		"工具",
	}
	toolNames := strings.Split(asString(row["tool_names"]), "\n")
	count := 0
	for _, name := range toolNames {
		if strings.TrimSpace(name) == "" {
			continue
		}
		count++
		lines = append(lines, fmt.Sprintf("  %2d. %s", count, name))
	}
	if count == 0 {
		lines = append(lines, "  无缓存工具；连接或刷新元数据后会出现。")
	}
	if notes := strings.TrimSpace(asString(row["notes"])); notes != "" {
		lines = append(lines, "", "备注", "  "+notes)
	}
	return strings.Join(lines, "\n")
}

func mcpToolNamesFromRow(row map[string]any) []string {
	parts := strings.Split(asString(row["tool_names"]), "\n")
	result := make([]string, 0, len(parts))
	seen := map[string]bool{}
	for _, part := range parts {
		name := strings.TrimSpace(part)
		if name == "" || seen[name] {
			continue
		}
		seen[name] = true
		result = append(result, name)
	}
	sort.Strings(result)
	return result
}

func mcpMutationPreview(response map[string]any) string {
	lines := []string{
		"MCP 操作",
		"  影响行数: " + fmt.Sprintf("%d", asInt(response["affectedRows"])),
		"  总变更数: " + fmt.Sprintf("%d", asInt(response["totalChanges"])),
	}
	if rows := asMapSlice(response["returningRows"]); len(rows) > 0 {
		lines = append(lines, "", "返回")
		for _, row := range rows {
			lines = append(lines, "  "+firstNonEmpty(asString(row["display_name"]), asString(row["id"])))
		}
	}
	if message := asString(response["message"]); message != "" {
		lines = append(lines, "", "消息", "  "+message)
	}
	return strings.Join(lines, "\n")
}

func normalizeMCPHeadersJSON(value string) (string, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" || trimmed == "{}" {
		return "", nil
	}
	var headers map[string]string
	if err := json.Unmarshal([]byte(trimmed), &headers); err != nil {
		return "", fmt.Errorf("Additional Headers 不是合法 JSON 对象或包含非字符串值: %w", err)
	}
	return compactJSON(headers)
}

func normalizeJSONStringArray(value, title string) (string, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" || trimmed == "[]" {
		return "", nil
	}
	values, err := parseMCPStringSetJSON(trimmed, title)
	if err != nil {
		return "", err
	}
	return compactJSON(sortedKeys(values))
}

func normalizeMCPApprovalPoliciesJSON(value string) (string, error) {
	policies, err := parseMCPApprovalPoliciesJSON(value)
	if err != nil {
		return "", err
	}
	return compactJSON(policies)
}

func updateMCPToolPolicyJSON(disabledJSON, policiesJSON, toolID string, enabled bool, policy string) (string, string, error) {
	toolID = strings.TrimSpace(toolID)
	if toolID == "" {
		return "", "", fmt.Errorf("工具 ID 不能为空")
	}
	disabled, err := parseMCPStringSetJSON(disabledJSON, "Disabled Tool IDs")
	if err != nil {
		return "", "", err
	}
	policies, err := parseMCPApprovalPoliciesJSON(policiesJSON)
	if err != nil {
		return "", "", err
	}

	if enabled {
		delete(disabled, toolID)
	} else {
		disabled[toolID] = true
	}
	switch policy {
	case "", "ask_every_time":
		delete(policies, toolID)
	case "always_allow", "always_deny":
		policies[toolID] = policy
	default:
		return "", "", fmt.Errorf("%s 的审批策略无效: %s", toolID, policy)
	}

	normalizedDisabled, err := compactJSON(sortedKeys(disabled))
	if err != nil {
		return "", "", err
	}
	normalizedPolicies, err := compactJSON(policies)
	if err != nil {
		return "", "", err
	}
	return normalizedDisabled, normalizedPolicies, nil
}

func parseMCPStringSetJSON(value, title string) (map[string]bool, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" || trimmed == "[]" {
		return map[string]bool{}, nil
	}
	var values []string
	if err := json.Unmarshal([]byte(trimmed), &values); err != nil {
		return nil, fmt.Errorf("%s 不是合法字符串 JSON 数组: %w", title, err)
	}
	result := make(map[string]bool, len(values))
	for _, value := range values {
		trimmedValue := strings.TrimSpace(value)
		if trimmedValue != "" {
			result[trimmedValue] = true
		}
	}
	return result, nil
}

func parseMCPApprovalPoliciesJSON(value string) (map[string]string, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" || trimmed == "{}" {
		return map[string]string{}, nil
	}
	var policies map[string]string
	if err := json.Unmarshal([]byte(trimmed), &policies); err != nil {
		return nil, fmt.Errorf("Tool Approval Policies 不是合法 JSON 对象: %w", err)
	}
	for toolID, policy := range policies {
		trimmedToolID := strings.TrimSpace(toolID)
		if trimmedToolID == "" {
			delete(policies, toolID)
			continue
		}
		switch policy {
		case "ask_every_time":
			delete(policies, toolID)
		case "always_allow", "always_deny":
			if trimmedToolID != toolID {
				delete(policies, toolID)
				policies[trimmedToolID] = policy
			}
		default:
			return nil, fmt.Errorf("%s 的审批策略无效: %s", toolID, policy)
		}
	}
	return policies, nil
}

func sortedKeys(values map[string]bool) []string {
	keys := make([]string, 0, len(values))
	for key, enabled := range values {
		if enabled {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	return keys
}

func normalizeMCPOAuthPayloadJSON(value string) (string, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" || trimmed == "{}" {
		return "", fmt.Errorf("OAuth Payload 需要包含 tokenEndpoint、clientID 与 grantType")
	}

	var payload struct {
		TokenEndpoint     string `json:"tokenEndpoint"`
		ClientID          string `json:"clientID"`
		ClientSecret      string `json:"clientSecret"`
		Scope             string `json:"scope"`
		GrantType         string `json:"grantType"`
		AuthorizationCode string `json:"authorizationCode"`
		RedirectURI       string `json:"redirectURI"`
		CodeVerifier      string `json:"codeVerifier"`
	}
	if err := json.Unmarshal([]byte(trimmed), &payload); err != nil {
		return "", fmt.Errorf("OAuth Payload 不是合法 JSON 对象: %w", err)
	}

	payload.TokenEndpoint = strings.TrimSpace(payload.TokenEndpoint)
	payload.ClientID = strings.TrimSpace(payload.ClientID)
	payload.ClientSecret = strings.TrimSpace(payload.ClientSecret)
	payload.Scope = strings.TrimSpace(payload.Scope)
	payload.GrantType = strings.TrimSpace(payload.GrantType)
	payload.AuthorizationCode = strings.TrimSpace(payload.AuthorizationCode)
	payload.RedirectURI = strings.TrimSpace(payload.RedirectURI)
	payload.CodeVerifier = strings.TrimSpace(payload.CodeVerifier)

	if err := validateHTTPURL(payload.TokenEndpoint, "OAuth Token Endpoint"); err != nil {
		return "", err
	}
	if payload.ClientID == "" {
		return "", fmt.Errorf("OAuth Payload 的 clientID 不能为空")
	}
	switch payload.GrantType {
	case "client_credentials":
	case "authorization_code":
		if payload.AuthorizationCode == "" || payload.RedirectURI == "" {
			return "", fmt.Errorf("authorization_code 需要填写 authorizationCode 与 redirectURI")
		}
	default:
		return "", fmt.Errorf("OAuth Payload 的 grantType 必须是 client_credentials 或 authorization_code")
	}

	normalized := map[string]string{
		"tokenEndpoint": payload.TokenEndpoint,
		"clientID":      payload.ClientID,
		"grantType":     payload.GrantType,
	}
	if payload.ClientSecret != "" {
		normalized["clientSecret"] = payload.ClientSecret
	}
	if payload.Scope != "" {
		normalized["scope"] = payload.Scope
	}
	if payload.AuthorizationCode != "" {
		normalized["authorizationCode"] = payload.AuthorizationCode
	}
	if payload.RedirectURI != "" {
		normalized["redirectURI"] = payload.RedirectURI
	}
	if payload.CodeVerifier != "" {
		normalized["codeVerifier"] = payload.CodeVerifier
	}
	return compactJSON(normalized)
}

func compactJSON(value any) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	if string(data) == "{}" || string(data) == "[]" {
		return "", nil
	}
	return string(data), nil
}

func tuiMCPTransportKindOptions() []huh.Option[string] {
	return []huh.Option[string]{
		huh.NewOption("Streamable HTTP (http)", "http"),
		huh.NewOption("SSE (sse)", "sse"),
		huh.NewOption("OAuth (oauth)", "oauth"),
	}
}

func tuiMCPApprovalPolicyOptions() []huh.Option[string] {
	return []huh.Option[string]{
		huh.NewOption("每次询问 (ask_every_time)", "ask_every_time"),
		huh.NewOption("总是允许 (always_allow)", "always_allow"),
		huh.NewOption("始终拒绝 (always_deny)", "always_deny"),
	}
}

func boolToSQLiteInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

func nullableTrimmed(value string) any {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return nil
	}
	return trimmed
}

func secretPresenceLabel(value string) string {
	if strings.TrimSpace(value) == "" {
		return "未设置"
	}
	return "已设置"
}

func unixNowSeconds() float64 {
	return float64(time.Now().UnixNano()) / float64(time.Second)
}

func newTUIUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Sprintf("00000000-0000-4000-8000-%012x", time.Now().UnixNano()&0xffffffffffff)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return strings.ToUpper(fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4],
		b[4:6],
		b[6:8],
		b[8:10],
		b[10:16],
	))
}
