package main

import (
	"strings"
	"testing"
)

func TestBuildMCPServerUpsertPayloadForHTTP(t *testing.T) {
	payload, resetMetadata, err := buildMCPServerUpsertPayload(mcpServerInput{
		ID:                       "server-1",
		DisplayName:              "GitHub",
		TransportKind:            "http",
		EndpointURL:              "https://mcp.example.com/mcp",
		APIKey:                   "token",
		AdditionalHeadersJSON:    `{"X-Test":"on"}`,
		DisabledToolIDsJSON:      `["danger"]`,
		ToolApprovalPoliciesJSON: `{"search":"always_allow","delete":"always_deny","ask":"ask_every_time"}`,
		IsSelectedForChat:        true,
	}, false)
	if err != nil {
		t.Fatalf("buildMCPServerUpsertPayload 返回错误: %v", err)
	}
	if resetMetadata {
		t.Fatal("新增 HTTP MCP 服务器不需要额外清理工具缓存")
	}
	if payload["command"] != "mutate_sqlite" || payload["database"] != "config" {
		t.Fatalf("payload 基础字段异常: %#v", payload)
	}
	sql := asString(payload["sql"])
	if !strings.Contains(sql, "INSERT INTO mcp_servers") || !strings.Contains(sql, "ON CONFLICT(id) DO UPDATE") {
		t.Fatalf("upsert SQL 异常: %s", sql)
	}
	parameters, ok := payload["parameters"].([]any)
	if !ok {
		t.Fatalf("parameters 类型 = %T, want []any", payload["parameters"])
	}
	if parameters[0] != "server-1" || parameters[1] != "GitHub" || parameters[4] != "http" {
		t.Fatalf("基础参数异常: %#v", parameters)
	}
	if parameters[5] != "https://mcp.example.com/mcp" {
		t.Fatalf("endpoint_url = %v", parameters[5])
	}
	if parameters[10] != `{"X-Test":"on"}` {
		t.Fatalf("additional_headers_json = %v", parameters[10])
	}
	if parameters[11] != `["danger"]` {
		t.Fatalf("disabled_tool_ids_json = %v", parameters[11])
	}
	if parameters[12] != `{"delete":"always_deny","search":"always_allow"}` {
		t.Fatalf("tool_approval_policies_json = %v", parameters[12])
	}
}

func TestBuildMCPServerUpsertPayloadNormalizesUUIDID(t *testing.T) {
	payload, _, err := buildMCPServerUpsertPayload(mcpServerInput{
		ID:                " 5b7bcb6c-4e7f-4d98-8f17-9fbf5d2c0a91 ",
		DisplayName:       "GitHub",
		TransportKind:     "http",
		EndpointURL:       "https://mcp.example.com/mcp",
		IsSelectedForChat: true,
	}, false)
	if err != nil {
		t.Fatalf("buildMCPServerUpsertPayload 返回错误: %v", err)
	}
	parameters := payload["parameters"].([]any)
	if parameters[0] != "5B7BCB6C-4E7F-4D98-8F17-9FBF5D2C0A91" {
		t.Fatalf("MCP UUID 未规范为大写: %#v", parameters[0])
	}
}

func TestBuildMCPServerUpdatePayloadMatchesExistingUUIDCaseInsensitively(t *testing.T) {
	payload, _, err := buildMCPServerUpdatePayload(mcpServerInput{
		ID:                "5b7bcb6c-4e7f-4d98-8f17-9fbf5d2c0a91",
		DisplayName:       "GitHub",
		TransportKind:     "http",
		EndpointURL:       "https://mcp.example.com/mcp",
		IsSelectedForChat: true,
	}, false)
	if err != nil {
		t.Fatalf("buildMCPServerUpdatePayload 返回错误: %v", err)
	}
	sql := asString(payload["sql"])
	if !strings.Contains(sql, "UPDATE mcp_servers") || strings.Contains(sql, "INSERT INTO mcp_servers") {
		t.Fatalf("编辑已有 MCP 服务器应使用 UPDATE 而不是 INSERT: %s", sql)
	}
	if !strings.Contains(sql, "WHERE id COLLATE NOCASE = ?") {
		t.Fatalf("编辑已有 MCP 服务器没有大小写不敏感匹配 ID: %s", sql)
	}
	parameters := payload["parameters"].([]any)
	if parameters[len(parameters)-1] != "5B7BCB6C-4E7F-4D98-8F17-9FBF5D2C0A91" {
		t.Fatalf("UPDATE 查询 ID 未规范为大写: %#v", parameters[len(parameters)-1])
	}
}

func TestMCPServerIDPayloadsNormalizeUUIDAndMatchCaseInsensitively(t *testing.T) {
	lowerID := "5b7bcb6c-4e7f-4d98-8f17-9fbf5d2c0a91"
	upperID := "5B7BCB6C-4E7F-4D98-8F17-9FBF5D2C0A91"

	payloads := []map[string]any{
		mcpToggleServerChatPayload(lowerID, true),
		mcpUpdatePoliciesPayload(lowerID, `["tool"]`, `{"tool":"always_allow"}`),
		mcpDeleteToolsPayload(lowerID),
		mcpDeleteServerPayload(lowerID),
	}
	for index, payload := range payloads {
		sql := asString(payload["sql"])
		if !strings.Contains(sql, "COLLATE NOCASE") {
			t.Fatalf("payload %d 没有大小写不敏感匹配 ID: %s", index, sql)
		}
		parameters := payload["parameters"].([]any)
		if parameters[len(parameters)-1] != upperID {
			t.Fatalf("payload %d 的 ID 参数 = %#v, want %s", index, parameters[len(parameters)-1], upperID)
		}
	}
}

func TestNewTUIUUIDUsesUppercaseCanonicalText(t *testing.T) {
	id := newTUIUUID()
	if id != strings.ToUpper(id) {
		t.Fatalf("newTUIUUID 生成了非大写 UUID: %s", id)
	}
	if !isUUIDText(id) {
		t.Fatalf("newTUIUUID 生成了非法 UUID: %s", id)
	}
}

func TestBuildMCPServerUpsertPayloadInfersSSEMessageEndpoint(t *testing.T) {
	payload, resetMetadata, err := buildMCPServerUpsertPayload(mcpServerInput{
		ID:                "server-1",
		DisplayName:       "SSE",
		TransportKind:     "sse",
		SSEEndpointURL:    "https://mcp.example.com/sse",
		IsSelectedForChat: true,
	}, true)
	if err != nil {
		t.Fatalf("buildMCPServerUpsertPayload 返回错误: %v", err)
	}
	if !resetMetadata {
		t.Fatal("编辑 MCP 服务器应清理旧工具缓存")
	}
	parameters := payload["parameters"].([]any)
	if parameters[4] != "sse" {
		t.Fatalf("transport_kind = %v", parameters[4])
	}
	if parameters[6] != "https://mcp.example.com/message" {
		t.Fatalf("message_endpoint_url = %v", parameters[6])
	}
	if parameters[7] != "https://mcp.example.com/sse" {
		t.Fatalf("sse_endpoint_url = %v", parameters[7])
	}
	if !strings.Contains(asString(payload["sql"]), "metadata_cached_at = NULL") {
		t.Fatalf("编辑 SQL 没有清理元数据缓存: %s", asString(payload["sql"]))
	}
}

func TestBuildMCPServerUpsertPayloadStoresOnlyActiveTransportFields(t *testing.T) {
	httpPayload, _, err := buildMCPServerUpsertPayload(mcpServerInput{
		ID:                    "server-http",
		DisplayName:           "HTTP",
		TransportKind:         "http",
		EndpointURL:           "https://mcp.example.com/mcp",
		APIKey:                " token ",
		AdditionalHeadersJSON: `{"X-Test":"on"}`,
		OAuthPayloadJSON:      `not-json`,
		IsSelectedForChat:     true,
	}, false)
	if err != nil {
		t.Fatalf("HTTP MCP payload 不应校验 OAuth 残留字段: %v", err)
	}
	httpParameters := httpPayload["parameters"].([]any)
	if httpParameters[9] != "token" || httpParameters[10] != `{"X-Test":"on"}` {
		t.Fatalf("HTTP 鉴权字段异常: %#v", httpParameters)
	}
	if httpParameters[13] != nil {
		t.Fatalf("HTTP 不应保存 OAuth Payload: %#v", httpParameters[13])
	}

	oauthPayload, _, err := buildMCPServerUpsertPayload(mcpServerInput{
		ID:                    "server-oauth",
		DisplayName:           "OAuth",
		TransportKind:         "oauth",
		EndpointURL:           "https://mcp.example.com/mcp",
		APIKey:                "token",
		AdditionalHeadersJSON: `{"X-Test":"on"}`,
		OAuthPayloadJSON:      `{"tokenEndpoint":"https://mcp.example.com/token","clientID":"client","grantType":"client_credentials"}`,
		IsSelectedForChat:     true,
	}, false)
	if err != nil {
		t.Fatalf("OAuth MCP payload 返回错误: %v", err)
	}
	oauthParameters := oauthPayload["parameters"].([]any)
	if oauthParameters[9] != nil || oauthParameters[10] != nil {
		t.Fatalf("OAuth 不应保存 Bearer Key 或 Header: %#v", oauthParameters)
	}
	if oauthParameters[13] != `{"clientID":"client","grantType":"client_credentials","tokenEndpoint":"https://mcp.example.com/token"}` {
		t.Fatalf("OAuth Payload 归一化异常: %#v", oauthParameters[13])
	}
}

func TestBuildMCPServerUpsertPayloadRejectsInvalidPolicy(t *testing.T) {
	_, _, err := buildMCPServerUpsertPayload(mcpServerInput{
		ID:                       "server-1",
		DisplayName:              "Bad",
		TransportKind:            "http",
		EndpointURL:              "https://mcp.example.com/mcp",
		ToolApprovalPoliciesJSON: `{"tool":"maybe"}`,
	}, false)
	if err == nil {
		t.Fatal("err = nil，期望拒绝未知审批策略")
	}
}

func TestMCPShouldResetMetadataOnlyForTransportChanges(t *testing.T) {
	original := mcpServerInput{
		ID:                       "server-1",
		DisplayName:              "Original",
		Notes:                    "old",
		TransportKind:            "http",
		EndpointURL:              "https://mcp.example.com/mcp",
		APIKey:                   "token",
		AdditionalHeadersJSON:    `{"X-Test":"on"}`,
		DisabledToolIDsJSON:      `["old"]`,
		ToolApprovalPoliciesJSON: `{"old":"always_allow"}`,
		IsSelectedForChat:        true,
	}

	renamed := original
	renamed.DisplayName = "Renamed"
	renamed.Notes = "new"
	renamed.IsSelectedForChat = false
	renamed.DisabledToolIDsJSON = `["old","new"]`
	renamed.ToolApprovalPoliciesJSON = `{"old":"always_deny"}`
	reset, err := mcpShouldResetMetadata(original, renamed, false)
	if err != nil {
		t.Fatalf("mcpShouldResetMetadata 返回错误: %v", err)
	}
	if reset {
		t.Fatal("只修改名称、备注、聊天路由或工具策略时不应清理 MCP metadata")
	}

	changedEndpoint := original
	changedEndpoint.EndpointURL = "https://mcp.example.com/other"
	reset, err = mcpShouldResetMetadata(original, changedEndpoint, false)
	if err != nil {
		t.Fatalf("endpoint 变化比较返回错误: %v", err)
	}
	if !reset {
		t.Fatal("Endpoint 改变时应清理 MCP metadata")
	}

	changedHeader := original
	changedHeader.AdditionalHeadersJSON = `{"X-Test":"off"}`
	reset, err = mcpShouldResetMetadata(original, changedHeader, false)
	if err != nil {
		t.Fatalf("header 变化比较返回错误: %v", err)
	}
	if !reset {
		t.Fatal("Header 改变时应清理 MCP metadata")
	}

	newServer := original
	newServer.EndpointURL = ""
	reset, err = mcpShouldResetMetadata(original, newServer, true)
	if err != nil {
		t.Fatalf("新增服务器不应提前校验旧 transport: %v", err)
	}
	if reset {
		t.Fatal("新增服务器不需要额外清理 MCP metadata")
	}
}

func TestMCPShouldResetMetadataForOAuthPayloadChanges(t *testing.T) {
	original := mcpServerInput{
		ID:                "server-1",
		DisplayName:       "OAuth",
		TransportKind:     "oauth",
		EndpointURL:       "https://mcp.example.com/mcp",
		OAuthPayloadJSON:  `{"tokenEndpoint":"https://mcp.example.com/token","clientID":"client","grantType":"client_credentials"}`,
		IsSelectedForChat: true,
	}

	renamed := original
	renamed.DisplayName = "Renamed"
	reset, err := mcpShouldResetMetadata(original, renamed, false)
	if err != nil {
		t.Fatalf("OAuth 改名比较返回错误: %v", err)
	}
	if reset {
		t.Fatal("OAuth 只改名不应清理 MCP metadata")
	}

	changedPayload := original
	changedPayload.OAuthPayloadJSON = `{"tokenEndpoint":"https://mcp.example.com/token","clientID":"client-2","grantType":"client_credentials"}`
	reset, err = mcpShouldResetMetadata(original, changedPayload, false)
	if err != nil {
		t.Fatalf("OAuth payload 变化比较返回错误: %v", err)
	}
	if !reset {
		t.Fatal("OAuth Payload 改变时应清理 MCP metadata")
	}
}

func TestUpdateMCPToolPolicyJSONDisablesAndAllowsTool(t *testing.T) {
	disabledJSON, policiesJSON, err := updateMCPToolPolicyJSON(
		`["old","old"]`,
		`{"old":"always_allow","search":"ask_every_time"}`,
		"search",
		false,
		"always_allow",
	)
	if err != nil {
		t.Fatalf("updateMCPToolPolicyJSON 返回错误: %v", err)
	}
	if disabledJSON != `["old","search"]` {
		t.Fatalf("disabledJSON = %q, want old/search", disabledJSON)
	}
	if policiesJSON != `{"old":"always_allow","search":"always_allow"}` {
		t.Fatalf("policiesJSON = %q, want old/search always_allow", policiesJSON)
	}
}

func TestUpdateMCPToolPolicyJSONEnablesAndClearsDefaultPolicy(t *testing.T) {
	disabledJSON, policiesJSON, err := updateMCPToolPolicyJSON(
		`["search","old"]`,
		`{"search":"always_deny"}`,
		"search",
		true,
		"ask_every_time",
	)
	if err != nil {
		t.Fatalf("updateMCPToolPolicyJSON 返回错误: %v", err)
	}
	if disabledJSON != `["old"]` {
		t.Fatalf("disabledJSON = %q, want old only", disabledJSON)
	}
	if policiesJSON != "" {
		t.Fatalf("policiesJSON = %q, want empty default map", policiesJSON)
	}
}

func TestMCPToolNamesFromRowDeduplicatesAndSorts(t *testing.T) {
	got := mcpToolNamesFromRow(map[string]any{"tool_names": "beta\nalpha\nbeta\n"})
	if strings.Join(got, ",") != "alpha,beta" {
		t.Fatalf("工具名 = %#v, want alpha/beta", got)
	}
}

func TestApplyMCPServersBuildsRowsAndPreview(t *testing.T) {
	model := newTUIModel(NewDebugServer("127.0.0.1", 7654), "127.0.0.1")
	model.applyMCPServers(map[string]any{
		"rows": []any{
			map[string]any{
				"id":                   "server-1",
				"display_name":         "GitHub",
				"transport_kind":       "http",
				"is_selected_for_chat": 1,
				"tool_count":           2,
				"endpoint":             "https://mcp.example.com/mcp",
			},
		},
	})

	rows := model.mcpServers.Rows()
	if len(rows) != 1 {
		t.Fatalf("MCP 行数 = %d, want 1", len(rows))
	}
	if rows[0][1] != "GitHub" || rows[0][3] != "是" || rows[0][4] != "2" {
		t.Fatalf("MCP 行内容异常: %#v", rows[0])
	}
	if !strings.Contains(model.preview.Value(), "已加入聊天: 1") {
		t.Fatalf("MCP 摘要缺少聊天路由统计: %q", model.preview.Value())
	}
}
