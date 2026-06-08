package main

import (
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestSendCommandFallbackToQueueWhenNoWebSocket(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 7654)

	ok := server.sendCommand(map[string]any{"command": "ping"})
	if !ok {
		t.Fatal("sendCommand 返回 false，期望 true")
	}
	if got := server.getCommandQueueSize(); got != 1 {
		t.Fatalf("队列长度 = %d, want 1", got)
	}
}

func TestSendCommandWithResponseCanResolveByRequestID(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 7654)
	requestID := "req_test_ok"
	resultCh := make(chan struct {
		resp map[string]any
		err  error
	}, 1)

	go func() {
		resp, err := server.sendCommandWithResponse(map[string]any{
			"command":    "ping",
			"request_id": requestID,
		}, 2*time.Second)
		resultCh <- struct {
			resp map[string]any
			err  error
		}{resp: resp, err: err}
	}()

	deadline := time.Now().Add(300 * time.Millisecond)
	for {
		server.mu.RLock()
		_, exists := server.pendingResponses[requestID]
		server.mu.RUnlock()
		if exists {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("等待 pendingResponses 注册超时")
		}
		time.Sleep(5 * time.Millisecond)
	}

	if ok := server.resolvePendingResponse(requestID, map[string]any{"status": "ok", "message": "pong"}); !ok {
		t.Fatal("resolvePendingResponse 返回 false，期望 true")
	}

	select {
	case result := <-resultCh:
		if result.err != nil {
			t.Fatalf("sendCommandWithResponse 返回错误: %v", result.err)
		}
		if result.resp["message"] != "pong" {
			t.Fatalf("message = %v, want pong", result.resp["message"])
		}
	case <-time.After(time.Second):
		t.Fatal("等待 sendCommandWithResponse 返回超时")
	}
}

func TestSendCommandWithResponseTimeout(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 7654)
	requestID := "req_timeout"

	resp, err := server.sendCommandWithResponse(map[string]any{
		"command":    "list",
		"path":       ".",
		"request_id": requestID,
	}, 40*time.Millisecond)

	if err == nil {
		t.Fatal("err = nil，期望超时错误")
	}
	if resp != nil {
		t.Fatalf("resp = %v, want nil", resp)
	}
	if !strings.Contains(err.Error(), "超时") {
		t.Fatalf("err = %q, want 包含“超时”", err.Error())
	}

	server.mu.RLock()
	_, exists := server.pendingResponses[requestID]
	server.mu.RUnlock()
	if exists {
		t.Fatalf("pendingResponses[%s] 仍存在，期望已清理", requestID)
	}
}

func TestWebSocketConnectionStatusExpiresWithoutActivity(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 7654)
	httpServer := httptest.NewServer(http.HandlerFunc(server.handleWebSocketUpgrade))
	defer httpServer.Close()

	wsURL := "ws" + strings.TrimPrefix(httpServer.URL, "http") + wsPath
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("WebSocket 连接测试服务失败: %v", err)
	}
	defer conn.Close()

	deadline := time.Now().Add(300 * time.Millisecond)
	for server.getDeviceConnection() == nil {
		if time.Now().After(deadline) {
			t.Fatal("等待服务端记录 WebSocket 连接超时")
		}
		time.Sleep(5 * time.Millisecond)
	}

	server.mu.Lock()
	server.lastWebSocketActivity = time.Now().Add(-webSocketConnectionTimeout - time.Second)
	server.mu.Unlock()

	connected, mode := server.getConnectionStatus()
	if connected {
		t.Fatalf("过期 WebSocket 连接仍显示在线: %s", mode)
	}
	if !strings.Contains(mode, "已断开") {
		t.Fatalf("过期 WebSocket 状态 = %q, want 包含“已断开”", mode)
	}
	if server.getDeviceConnection() != nil {
		t.Fatal("过期 WebSocket 状态检查后连接仍未清理")
	}
}

func TestHTTPPollConnectionStatusExpiresAfterTimeout(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 7654)
	server.mu.Lock()
	server.lastPollTime = time.Now().Add(-httpPollFreshTimeout - time.Second)
	server.mu.Unlock()

	connected, mode := server.getConnectionStatus()
	if connected {
		t.Fatalf("过期 HTTP 轮询仍显示在线: %s", mode)
	}
	if !strings.Contains(mode, "已断开") {
		t.Fatalf("过期 HTTP 轮询状态 = %q, want 包含“已断开”", mode)
	}
}

func TestBonjourTXTRecordsExposePorts(t *testing.T) {
	server := NewDebugServer("127.0.0.1", 7654)
	records := strings.Join(server.bonjourTXTRecords(), "\n")

	for _, want := range []string{
		"proto=etos-debug-v1",
		"host=",
		"port=7654",
		"http_port=7654",
		"ws_path=/ws",
		"openai_path=/v1/chat/completions",
	} {
		if !strings.Contains(records, want) {
			t.Fatalf("Bonjour TXT 缺少 %q，当前记录: %v", want, records)
		}
	}
}

func TestBonjourInstanceNameFallback(t *testing.T) {
	if got := bonjourInstanceName("  "); got != "ETOS Debug" {
		t.Fatalf("空主机名实例名 = %q, want ETOS Debug", got)
	}
	if got := bonjourInstanceName("MacBook"); got != "ETOS Debug MacBook" {
		t.Fatalf("实例名 = %q, want ETOS Debug MacBook", got)
	}
}

func TestParsePortFromArgsUsesSingleDebugPort(t *testing.T) {
	port, err := parsePortFromArgs([]string{"etos-debug", "7655"})
	if err != nil {
		t.Fatalf("parsePortFromArgs 返回错误: %v", err)
	}
	if port != 7655 {
		t.Fatalf("port = %d, want 7655", port)
	}

	if _, err := parsePortFromArgs([]string{"etos-debug", "8765", "7654", "8080"}); err == nil {
		t.Fatal("旧三端口参数未返回错误")
	}
}

func TestStartHTTPServerReportsOccupiedPort(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("占用临时端口失败: %v", err)
	}
	defer listener.Close()

	port := listener.Addr().(*net.TCPAddr).Port
	server := NewDebugServer("127.0.0.1", port)
	if server.startHTTPServer() {
		t.Fatal("端口被占用时 startHTTPServer 返回 true")
	}

	started, message := server.getServiceStatus()
	if started {
		t.Fatal("端口被占用时 serviceStarted = true")
	}
	if !strings.Contains(message, "已被占用") {
		t.Fatalf("serviceError = %q, want 包含“已被占用”", message)
	}
}
