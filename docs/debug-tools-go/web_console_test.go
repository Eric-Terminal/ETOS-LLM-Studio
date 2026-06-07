package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func decodeJSONBody(t *testing.T, recorder *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var payload map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatalf("响应不是合法 JSON: %v", err)
	}
	return payload
}

func resolveNextPendingResponse(server *DebugServer, response map[string]any) {
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		server.mu.RLock()
		var requestID string
		for id := range server.pendingResponses {
			requestID = id
			break
		}
		server.mu.RUnlock()
		if requestID != "" {
			_ = server.resolvePendingResponse(requestID, response)
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestInferAPIErrorCode(t *testing.T) {
	cases := []struct {
		name    string
		message string
		want    string
	}{
		{name: "参数错误", message: "缺少 path 参数", want: "INVALID_ARGS"},
		{name: "未找到", message: "未找到会话", want: "NOT_FOUND"},
		{name: "超时", message: "等待命令响应超时", want: "TIMEOUT"},
		{name: "设备断开", message: "设备已断开连接", want: "DEVICE_DISCONNECTED"},
		{name: "未知错误", message: "something else", want: "DEVICE_ERROR"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := inferAPIErrorCode(tc.message); got != tc.want {
				t.Fatalf("inferAPIErrorCode(%q) = %q, want %q", tc.message, got, tc.want)
			}
		})
	}
}

func TestInferAPIHTTPStatus(t *testing.T) {
	cases := []struct {
		code string
		want int
	}{
		{code: "INVALID_ARGS", want: http.StatusBadRequest},
		{code: "NOT_FOUND", want: http.StatusNotFound},
		{code: "TIMEOUT", want: http.StatusGatewayTimeout},
		{code: "DEVICE_DISCONNECTED", want: http.StatusServiceUnavailable},
		{code: "UNKNOWN", want: http.StatusBadGateway},
	}

	for _, tc := range cases {
		if got := inferAPIHTTPStatus(tc.code); got != tc.want {
			t.Fatalf("inferAPIHTTPStatus(%q) = %d, want %d", tc.code, got, tc.want)
		}
	}
}

func TestExecuteAPICommandTimeoutReturnsStructuredError(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 8765, 7654, 8080)
	recorder := httptest.NewRecorder()

	server.executeAPICommand(recorder, map[string]any{"command": "list", "path": "."}, 30*time.Millisecond)

	if recorder.Code != http.StatusGatewayTimeout {
		t.Fatalf("状态码 = %d, want %d", recorder.Code, http.StatusGatewayTimeout)
	}

	payload := decodeJSONBody(t, recorder)
	if payload["status"] != "error" {
		t.Fatalf("status = %v, want error", payload["status"])
	}
	if payload["error_code"] != "TIMEOUT" {
		t.Fatalf("error_code = %v, want TIMEOUT", payload["error_code"])
	}
}

func TestHandleAPIFilesReadRequiresPath(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 8765, 7654, 8080)
	req := httptest.NewRequest(http.MethodPost, "/api/files/read", strings.NewReader(`{}`))
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()

	server.handleAPIFilesRead(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("状态码 = %d, want %d", recorder.Code, http.StatusBadRequest)
	}
	payload := decodeJSONBody(t, recorder)
	if payload["status"] != "error" {
		t.Fatalf("status = %v, want error", payload["status"])
	}
}

func TestHandleAPIStatusUsesHTTPPollingWhenWSDisconnected(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 8765, 7654, 8080)
	server.mu.Lock()
	server.lastPollTime = time.Now()
	server.mu.Unlock()

	req := httptest.NewRequest(http.MethodGet, "/api/status", nil)
	recorder := httptest.NewRecorder()
	server.handleAPIStatus(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, want %d", recorder.Code, http.StatusOK)
	}

	payload := decodeJSONBody(t, recorder)
	if payload["connected"] != true {
		t.Fatalf("connected = %v, want true", payload["connected"])
	}
	if payload["mode"] != "http_polling" {
		t.Fatalf("mode = %v, want http_polling", payload["mode"])
	}
}

func TestHandleAPISQLiteTablesRequiresDatabase(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 8765, 7654, 8080)
	req := httptest.NewRequest(http.MethodPost, "/api/sqlite/tables", strings.NewReader(`{}`))
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()

	server.handleAPISQLiteTables(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("状态码 = %d, want %d", recorder.Code, http.StatusBadRequest)
	}
	payload := decodeJSONBody(t, recorder)
	if payload["status"] != "error" {
		t.Fatalf("status = %v, want error", payload["status"])
	}
}

func TestHandleAPISQLiteQueryRequiresDatabaseAndSQL(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 8765, 7654, 8080)
	req := httptest.NewRequest(http.MethodPost, "/api/sqlite/query", strings.NewReader(`{"database":"chat"}`))
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()

	server.handleAPISQLiteQuery(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("状态码 = %d, want %d", recorder.Code, http.StatusBadRequest)
	}
	payload := decodeJSONBody(t, recorder)
	if payload["status"] != "error" {
		t.Fatalf("status = %v, want error", payload["status"])
	}
}

func TestHandleAPISQLiteQueryForwardsToDeviceCommand(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 8765, 7654, 8080)
	req := httptest.NewRequest(
		http.MethodPost,
		"/api/sqlite/query",
		strings.NewReader(`{"database":"chat","sql":"SELECT 1","max_rows":5}`),
	)
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()

	go func() {
		deadline := time.Now().Add(time.Second)
		for time.Now().Before(deadline) {
			server.mu.RLock()
			var requestID string
			for id := range server.pendingResponses {
				requestID = id
				break
			}
			server.mu.RUnlock()
			if requestID != "" {
				_ = server.resolvePendingResponse(requestID, map[string]any{
					"status":   "ok",
					"database": "chat",
					"columns":  []any{"one"},
					"rows":     []any{map[string]any{"one": 1}},
				})
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
	}()

	server.handleAPISQLiteQuery(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, want %d, body=%s", recorder.Code, http.StatusOK, recorder.Body.String())
	}
	payload := decodeJSONBody(t, recorder)
	if payload["status"] != "ok" {
		t.Fatalf("status = %v, want ok", payload["status"])
	}

	server.mu.RLock()
	defer server.mu.RUnlock()
	if len(server.commandQueue) != 1 {
		t.Fatalf("commandQueue 长度 = %d, want 1", len(server.commandQueue))
	}
	if server.commandQueue[0]["command"] != "query_sqlite" {
		t.Fatalf("command = %v, want query_sqlite", server.commandQueue[0]["command"])
	}
}

func TestHandleAPIAppConfigSetRequiresKey(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 8765, 7654, 8080)
	req := httptest.NewRequest(http.MethodPost, "/api/app-config/set", strings.NewReader(`{"value":"true"}`))
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()

	server.handleAPIAppConfigSet(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("状态码 = %d, want %d", recorder.Code, http.StatusBadRequest)
	}
	payload := decodeJSONBody(t, recorder)
	if payload["status"] != "error" {
		t.Fatalf("status = %v, want error", payload["status"])
	}
}

func TestHandleAPIAppConfigSetForwardsToDeviceCommand(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 8765, 7654, 8080)
	req := httptest.NewRequest(
		http.MethodPost,
		"/api/app-config/set",
		strings.NewReader(`{"key":"enableStreaming","value":"false"}`),
	)
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()

	go func() {
		deadline := time.Now().Add(time.Second)
		for time.Now().Before(deadline) {
			server.mu.RLock()
			var requestID string
			for id := range server.pendingResponses {
				requestID = id
				break
			}
			server.mu.RUnlock()
			if requestID != "" {
				_ = server.resolvePendingResponse(requestID, map[string]any{
					"status":  "ok",
					"message": "配置已保存",
					"setting": map[string]any{"key": "enableStreaming", "value_text": "false"},
				})
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
	}()

	server.handleAPIAppConfigSet(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, want %d, body=%s", recorder.Code, http.StatusOK, recorder.Body.String())
	}
	payload := decodeJSONBody(t, recorder)
	if payload["status"] != "ok" {
		t.Fatalf("status = %v, want ok", payload["status"])
	}

	server.mu.RLock()
	defer server.mu.RUnlock()
	if len(server.commandQueue) != 1 {
		t.Fatalf("commandQueue 长度 = %d, want 1", len(server.commandQueue))
	}
	if server.commandQueue[0]["command"] != "app_config_set" {
		t.Fatalf("command = %v, want app_config_set", server.commandQueue[0]["command"])
	}
	if server.commandQueue[0]["key"] != "enableStreaming" {
		t.Fatalf("key = %v, want enableStreaming", server.commandQueue[0]["key"])
	}
}

func TestHandleAPIProviderUpsertRequiresNameWhenCreating(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 8765, 7654, 8080)
	req := httptest.NewRequest(http.MethodPost, "/api/providers/upsert", strings.NewReader(`{"base_url":"https://api.example.com/v1"}`))
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()

	server.handleAPIProviderUpsert(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("状态码 = %d, want %d", recorder.Code, http.StatusBadRequest)
	}
	payload := decodeJSONBody(t, recorder)
	if payload["status"] != "error" {
		t.Fatalf("status = %v, want error", payload["status"])
	}
}

func TestHandleAPIProviderUpsertForwardsToDeviceCommand(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 8765, 7654, 8080)
	req := httptest.NewRequest(
		http.MethodPost,
		"/api/providers/upsert",
		strings.NewReader(`{"name":"示例 Provider","base_url":"https://api.example.com/v1","api_key":"sk-test","api_format":"openai-compatible","header_overrides":{"X-Test":"on"}}`),
	)
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()

	go resolveNextPendingResponse(server, map[string]any{
		"status": "ok",
		"provider": map[string]any{
			"id":        "11111111-1111-4111-8111-111111111111",
			"name":      "示例 Provider",
			"baseURL":   "https://api.example.com/v1",
			"apiFormat": "openai-compatible",
		},
	})

	server.handleAPIProviderUpsert(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, want %d, body=%s", recorder.Code, http.StatusOK, recorder.Body.String())
	}
	payload := decodeJSONBody(t, recorder)
	if payload["status"] != "ok" {
		t.Fatalf("status = %v, want ok", payload["status"])
	}

	server.mu.RLock()
	defer server.mu.RUnlock()
	if len(server.commandQueue) != 1 {
		t.Fatalf("commandQueue 长度 = %d, want 1", len(server.commandQueue))
	}
	command := server.commandQueue[0]
	if command["command"] != "provider_upsert" {
		t.Fatalf("command = %v, want provider_upsert", command["command"])
	}
	if command["name"] != "示例 Provider" {
		t.Fatalf("name = %v, want 示例 Provider", command["name"])
	}
	if command["api_key"] != "sk-test" {
		t.Fatalf("api_key = %v, want sk-test", command["api_key"])
	}
	headerOverrides, ok := command["header_overrides"].(map[string]any)
	if !ok {
		t.Fatalf("header_overrides 类型 = %T, want map[string]any", command["header_overrides"])
	}
	if headerOverrides["X-Test"] != "on" {
		t.Fatalf("X-Test = %v, want on", headerOverrides["X-Test"])
	}
}

func TestHandleAPIProviderModelUpsertRequiresProviderID(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 8765, 7654, 8080)
	req := httptest.NewRequest(http.MethodPost, "/api/providers/models/upsert", strings.NewReader(`{"model_name":"gpt-test"}`))
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()

	server.handleAPIProviderModelUpsert(recorder, req)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("状态码 = %d, want %d", recorder.Code, http.StatusBadRequest)
	}
	payload := decodeJSONBody(t, recorder)
	if payload["status"] != "error" {
		t.Fatalf("status = %v, want error", payload["status"])
	}
}

func TestHandleAPIProviderModelUpsertForwardsToDeviceCommand(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 8765, 7654, 8080)
	req := httptest.NewRequest(
		http.MethodPost,
		"/api/providers/models/upsert",
		strings.NewReader(`{"provider_id":"22222222-2222-4222-8222-222222222222","model_name":"gpt-test","display_name":"GPT Test","is_activated":false,"kind":"chat","capabilities":["toolCalling"],"override_parameters":{"temperature":0.2}}`),
	)
	req.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()

	go resolveNextPendingResponse(server, map[string]any{
		"status": "ok",
		"provider": map[string]any{
			"id":   "22222222-2222-4222-8222-222222222222",
			"name": "示例 Provider",
		},
		"model": map[string]any{
			"id":        "33333333-3333-4333-8333-333333333333",
			"modelName": "gpt-test",
		},
	})

	server.handleAPIProviderModelUpsert(recorder, req)

	if recorder.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, want %d, body=%s", recorder.Code, http.StatusOK, recorder.Body.String())
	}
	payload := decodeJSONBody(t, recorder)
	if payload["status"] != "ok" {
		t.Fatalf("status = %v, want ok", payload["status"])
	}

	server.mu.RLock()
	defer server.mu.RUnlock()
	if len(server.commandQueue) != 1 {
		t.Fatalf("commandQueue 长度 = %d, want 1", len(server.commandQueue))
	}
	command := server.commandQueue[0]
	if command["command"] != "provider_model_upsert" {
		t.Fatalf("command = %v, want provider_model_upsert", command["command"])
	}
	if command["provider_id"] != "22222222-2222-4222-8222-222222222222" {
		t.Fatalf("provider_id = %v, want 22222222-2222-4222-8222-222222222222", command["provider_id"])
	}
	if command["model_name"] != "gpt-test" {
		t.Fatalf("model_name = %v, want gpt-test", command["model_name"])
	}
	if command["is_activated"] != false {
		t.Fatalf("is_activated = %v, want false", command["is_activated"])
	}
}
