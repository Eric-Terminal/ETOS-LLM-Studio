package main

import (
	"embed"
	"encoding/base64"
	"io/fs"
	"net/http"
	"path"
	"strings"
	"time"
)

//go:embed web/*
var webConsoleAssets embed.FS

var (
	webConsoleFS         fs.FS
	webConsoleFileServer http.Handler
)

func init() {
	sub, err := fs.Sub(webConsoleAssets, "web")
	if err != nil {
		return
	}
	webConsoleFS = sub
	webConsoleFileServer = http.FileServer(http.FS(sub))
}

func (s *DebugServer) registerWebRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/api/status", s.handleAPIStatus)

	mux.HandleFunc("/api/files/list", s.handleAPIFilesList)
	mux.HandleFunc("/api/files/read", s.handleAPIFilesRead)
	mux.HandleFunc("/api/files/write", s.handleAPIFilesWrite)
	mux.HandleFunc("/api/files/delete", s.handleAPIFilesDelete)
	mux.HandleFunc("/api/files/mkdir", s.handleAPIFilesMkdir)

	mux.HandleFunc("/api/providers", s.handleAPIProviders)
	mux.HandleFunc("/api/providers/save", s.handleAPIProvidersSave)

	mux.HandleFunc("/api/sessions", s.handleAPISessions)
	mux.HandleFunc("/api/sessions/get", s.handleAPISessionGet)
	mux.HandleFunc("/api/sessions/create", s.handleAPISessionCreate)
	mux.HandleFunc("/api/sessions/delete", s.handleAPISessionDelete)
	mux.HandleFunc("/api/sessions/update_meta", s.handleAPISessionUpdateMeta)
	mux.HandleFunc("/api/sessions/update_messages", s.handleAPISessionUpdateMessages)

	mux.HandleFunc("/api/memories", s.handleAPIMemories)
	mux.HandleFunc("/api/memories/update", s.handleAPIMemoryUpdate)
	mux.HandleFunc("/api/memories/reembed_all", s.handleAPIMemoriesReembedAll)

	mux.HandleFunc("/api/openai-captures", s.handleAPIOpenAICaptures)
	mux.HandleFunc("/api/openai-captures/resolve", s.handleAPIOpenAICapturesResolve)

	mux.HandleFunc("/", s.handleWebConsole)
}

func (s *DebugServer) handleWebConsole(w http.ResponseWriter, r *http.Request) {
	if strings.HasPrefix(r.URL.Path, "/api/") {
		http.NotFound(w, r)
		return
	}
	if webConsoleFS == nil {
		s.handleHTTPPing(w, r)
		return
	}

	if r.URL.Path == "/" || r.URL.Path == "/index.html" {
		serveEmbeddedFile(w, "index.html")
		return
	}

	requested := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
	if requested == "." || requested == "" {
		requested = "index.html"
	}

	if _, err := fs.Stat(webConsoleFS, requested); err == nil {
		webConsoleFileServer.ServeHTTP(w, r)
		return
	}

	// SPA 回退
	serveEmbeddedFile(w, "index.html")
}

func serveEmbeddedFile(w http.ResponseWriter, filename string) {
	if webConsoleFS == nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"status": "error", "message": "Web 控制台资源不存在"})
		return
	}
	data, err := fs.ReadFile(webConsoleFS, filename)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"status": "error", "message": "Web 控制台资源读取失败"})
		return
	}

	if strings.HasSuffix(filename, ".html") {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
	}
	_, _ = w.Write(data)
}

func (s *DebugServer) handleAPIStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 GET"})
		return
	}

	s.mu.RLock()
	wsConnected := s.deviceConn != nil
	deviceName := s.deviceName
	lastPoll := s.lastPollTime
	queueSize := len(s.commandQueue)
	pendingCount := len(s.pendingResponses)
	s.mu.RUnlock()

	httpPollingAlive := !lastPoll.IsZero() && time.Since(lastPoll) <= 15*time.Second
	mode := "disconnected"
	if wsConnected {
		mode = "websocket"
	} else if httpPollingAlive {
		mode = "http_polling"
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":             "ok",
		"connected":          wsConnected || httpPollingAlive,
		"mode":               mode,
		"device_name":        deviceName,
		"queue_size":         queueSize,
		"pending_requests":   pendingCount,
		"http_polling_alive": httpPollingAlive,
	})
}

func decodeRequestMap(r *http.Request) (map[string]any, error) {
	var payload map[string]any
	if err := decodeRequestJSON(r, &payload); err != nil {
		return nil, err
	}
	if payload == nil {
		payload = map[string]any{}
	}
	return payload, nil
}

func (s *DebugServer) executeAPICommand(w http.ResponseWriter, command map[string]any, timeout time.Duration) {
	if timeout <= 0 {
		timeout = 35 * time.Second
	}
	response, err := s.sendCommandWithResponse(command, timeout)
	if err != nil {
		statusCode, errorCode := inferAPICommandError(err.Error())
		writeJSON(w, statusCode, map[string]any{
			"status":     "error",
			"error_code": errorCode,
			"message":    err.Error(),
		})
		return
	}

	if asString(response["status"]) == "error" {
		message := asString(response["message"])
		errorCode := asString(response["error_code"])
		if errorCode == "" {
			errorCode = inferAPIErrorCode(message)
			response["error_code"] = errorCode
		}
		writeJSON(w, inferAPIHTTPStatus(errorCode), response)
		return
	}

	writeJSON(w, http.StatusOK, response)
}

func inferAPICommandError(message string) (int, string) {
	msg := strings.ToLower(strings.TrimSpace(message))
	switch {
	case strings.Contains(msg, "超时"):
		return http.StatusGatewayTimeout, "TIMEOUT"
	case strings.Contains(msg, "未连接"), strings.Contains(msg, "发送失败"), strings.Contains(msg, "connection closed"):
		return http.StatusServiceUnavailable, "DEVICE_DISCONNECTED"
	default:
		return http.StatusBadGateway, "DEVICE_COMMAND_FAILED"
	}
}

func inferAPIErrorCode(message string) string {
	msg := strings.ToLower(strings.TrimSpace(message))
	switch {
	case strings.Contains(msg, "缺少"), strings.Contains(msg, "无效"), strings.Contains(msg, "不能为空"), strings.Contains(msg, "格式错误"), strings.Contains(msg, "顶层必须"):
		return "INVALID_ARGS"
	case strings.Contains(msg, "未找到"), strings.Contains(msg, "不存在"):
		return "NOT_FOUND"
	case strings.Contains(msg, "超时"):
		return "TIMEOUT"
	case strings.Contains(msg, "未连接"), strings.Contains(msg, "断开"):
		return "DEVICE_DISCONNECTED"
	default:
		return "DEVICE_ERROR"
	}
}

func inferAPIHTTPStatus(errorCode string) int {
	switch strings.TrimSpace(strings.ToUpper(errorCode)) {
	case "INVALID_ARGS":
		return http.StatusBadRequest
	case "NOT_FOUND":
		return http.StatusNotFound
	case "TIMEOUT":
		return http.StatusGatewayTimeout
	case "DEVICE_DISCONNECTED":
		return http.StatusServiceUnavailable
	default:
		return http.StatusBadGateway
	}
}

func (s *DebugServer) handleAPIFilesList(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}
	payload, err := decodeRequestMap(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}
	path := asString(payload["path"])
	if path == "" {
		path = "."
	}
	s.executeAPICommand(w, map[string]any{"command": "list", "path": path}, 20*time.Second)
}

func (s *DebugServer) handleAPIFilesRead(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}
	payload, err := decodeRequestMap(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}
	filePath := asString(payload["path"])
	if filePath == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": "缺少 path 参数"})
		return
	}
	s.executeAPICommand(w, map[string]any{"command": "download", "path": filePath}, 30*time.Second)
}

func (s *DebugServer) handleAPIFilesWrite(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}
	payload, err := decodeRequestMap(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}
	filePath := asString(payload["path"])
	if filePath == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": "缺少 path 参数"})
		return
	}

	data := asString(payload["data"])
	if data == "" {
		if content := asString(payload["content"]); content != "" {
			data = base64.StdEncoding.EncodeToString([]byte(content))
		}
	}
	if data == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": "缺少 data 或 content"})
		return
	}

	s.executeAPICommand(w, map[string]any{"command": "upload", "path": filePath, "data": data}, 45*time.Second)
}

func (s *DebugServer) handleAPIFilesDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}
	payload, err := decodeRequestMap(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}
	filePath := asString(payload["path"])
	if filePath == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": "缺少 path 参数"})
		return
	}
	s.executeAPICommand(w, map[string]any{"command": "delete", "path": filePath}, 30*time.Second)
}

func (s *DebugServer) handleAPIFilesMkdir(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}
	payload, err := decodeRequestMap(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}
	dirPath := asString(payload["path"])
	if dirPath == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": "缺少 path 参数"})
		return
	}
	s.executeAPICommand(w, map[string]any{"command": "mkdir", "path": dirPath}, 30*time.Second)
}

func (s *DebugServer) handleAPIProviders(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 GET"})
		return
	}
	s.executeAPICommand(w, map[string]any{"command": "providers_list"}, 25*time.Second)
}

func (s *DebugServer) handleAPIProvidersSave(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}
	payload, err := decodeRequestMap(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}
	providers, ok := payload["providers"]
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": "缺少 providers 参数"})
		return
	}
	s.executeAPICommand(w, map[string]any{"command": "providers_save", "providers": providers}, 45*time.Second)
}

func (s *DebugServer) handleAPISessions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 GET"})
		return
	}
	s.executeAPICommand(w, map[string]any{"command": "sessions_list"}, 25*time.Second)
}

func (s *DebugServer) handleAPISessionGet(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}
	payload, err := decodeRequestMap(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}
	sessionID := asString(payload["session_id"])
	if sessionID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": "缺少 session_id 参数"})
		return
	}
	s.executeAPICommand(w, map[string]any{"command": "session_get", "session_id": sessionID}, 30*time.Second)
}

func (s *DebugServer) handleAPISessionCreate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}
	payload, err := decodeRequestMap(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}
	command := map[string]any{"command": "session_create"}
	if name := asString(payload["name"]); name != "" {
		command["name"] = name
	}
	if topic := asString(payload["topic_prompt"]); topic != "" {
		command["topic_prompt"] = topic
	}
	if enhanced := asString(payload["enhanced_prompt"]); enhanced != "" {
		command["enhanced_prompt"] = enhanced
	}
	s.executeAPICommand(w, command, 30*time.Second)
}

func (s *DebugServer) handleAPISessionDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}
	payload, err := decodeRequestMap(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}
	sessionID := asString(payload["session_id"])
	if sessionID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": "缺少 session_id 参数"})
		return
	}
	s.executeAPICommand(w, map[string]any{"command": "session_delete", "session_id": sessionID}, 30*time.Second)
}

func (s *DebugServer) handleAPISessionUpdateMeta(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}
	payload, err := decodeRequestMap(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}
	sessionRaw, ok := payload["session"]
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": "缺少 session 参数"})
		return
	}
	s.executeAPICommand(w, map[string]any{"command": "session_update_meta", "session": sessionRaw}, 45*time.Second)
}

func (s *DebugServer) handleAPISessionUpdateMessages(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}
	payload, err := decodeRequestMap(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}
	sessionID := asString(payload["session_id"])
	messages, ok := payload["messages"]
	if sessionID == "" || !ok {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": "缺少 session_id 或 messages 参数"})
		return
	}
	s.executeAPICommand(w, map[string]any{
		"command":    "session_update_messages",
		"session_id": sessionID,
		"messages":   messages,
	}, 60*time.Second)
}

func (s *DebugServer) handleAPIMemories(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 GET"})
		return
	}
	s.executeAPICommand(w, map[string]any{"command": "memories_list"}, 30*time.Second)
}

func (s *DebugServer) handleAPIMemoryUpdate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}
	payload, err := decodeRequestMap(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}
	memoryID := asString(payload["memory_id"])
	if memoryID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": "缺少 memory_id 参数"})
		return
	}
	command := map[string]any{
		"command":   "memory_update",
		"memory_id": memoryID,
	}
	if content, ok := payload["content"]; ok {
		command["content"] = content
	}
	if archived, ok := payload["is_archived"]; ok {
		command["is_archived"] = archived
	}
	s.executeAPICommand(w, command, 45*time.Second)
}

func (s *DebugServer) handleAPIMemoriesReembedAll(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}
	s.executeAPICommand(w, map[string]any{"command": "memories_reembed_all"}, 15*time.Minute)
}

func (s *DebugServer) handleAPIOpenAICaptures(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 GET"})
		return
	}
	s.executeAPICommand(w, map[string]any{"command": "openai_queue_list"}, 20*time.Second)
}

func (s *DebugServer) handleAPIOpenAICapturesResolve(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}
	payload, err := decodeRequestMap(r)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}
	command := map[string]any{
		"command": "openai_queue_resolve",
		"save":    true,
	}
	if v, ok := payload["save"]; ok {
		command["save"] = v
	}
	if id := asString(payload["id"]); id != "" {
		command["id"] = id
	}
	s.executeAPICommand(w, command, 30*time.Second)
}
