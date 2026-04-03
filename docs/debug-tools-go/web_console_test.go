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
