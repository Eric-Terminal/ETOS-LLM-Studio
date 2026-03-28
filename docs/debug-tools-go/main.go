package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

var (
	// 在 CI 中可通过 -ldflags 注入
	version = "dev"

	// 默认开启详细日志，保持与 Python 工具一致
	debugMode = true
)

const (
	defaultHost      = "0.0.0.0"
	defaultWSPort    = 8765
	defaultHTTPPort  = 7654
	defaultProxyPort = 8080
)

type DebugServer struct {
	host      string
	wsPort    int
	httpPort  int
	proxyPort int

	mu        sync.RWMutex
	wsWriteMu sync.Mutex

	deviceConn *websocket.Conn
	deviceName string

	lastPollTime time.Time

	commandQueue []map[string]any

	streamBackupDir       string
	uploadFileQueue       map[string]string
	uploadInProgress      bool
	downloadInProgress    bool
	downloadFileCount     int
	downloadExpectedTotal int

	compatibleDownloadInProgress bool
	compatibleFileList           []string
	compatibleDownloadEvent      chan struct{}

	pollHTTPServer  *http.Server
	proxyHTTPServer *http.Server
	wsHTTPServer    *http.Server
}

func NewDebugServer(host string, wsPort, httpPort, proxyPort int) *DebugServer {
	return &DebugServer{
		host:            host,
		wsPort:          wsPort,
		httpPort:        httpPort,
		proxyPort:       proxyPort,
		deviceName:      "未知设备",
		uploadFileQueue: map[string]string{},
		commandQueue:    make([]map[string]any, 0, 8),
	}
}

func getLocalIP() string {
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		return "无法获取IP"
	}
	defer conn.Close()

	localAddr, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok {
		return "无法获取IP"
	}
	return localAddr.IP.String()
}

func (s *DebugServer) run(ctx context.Context) error {
	localIP := getLocalIP()
	fmt.Printf(`
╔══════════════════════════════════════════════════════════════╗
║  ETOS LLM Studio - Go 版反向探针调试服务器                  ║
╚══════════════════════════════════════════════════════════════╝

🖥️  本机局域网IP: %s
📡 WebSocket 服务器: ws://%s:%d (推荐)
🌐 HTTP 轮询服务器: http://%s:%d (备用)
🌐 HTTP 代理服务器: http://%s:%d

💡 使用说明:
  1. 在设备上输入主机: %s
  2. WebSocket 端口: %d (模拟器首选)
  3. HTTP 轮询端口: %d (真机备用)
  4. 设备连接后会自动进入操作菜单
  5. OpenAI API 设置为: http://%s:%d

⚙️  调试模式: %s
🔖 版本: %s

⏳ 等待设备连接...
`, localIP, localIP, s.wsPort, localIP, s.httpPort, localIP, s.proxyPort, localIP, s.wsPort, s.httpPort, localIP, s.proxyPort, boolToCN(debugMode), version)

	s.startHTTPServers()
	s.startWebSocketServer()

	menuDone := make(chan error, 1)
	go func() {
		menuDone <- s.interactiveMenu(ctx)
	}()

	select {
	case <-ctx.Done():
		fmt.Println("\n\n👋 收到退出信号，正在关闭服务器...")
	case err := <-menuDone:
		if err != nil && !errors.Is(err, context.Canceled) {
			fmt.Printf("\n❌ 菜单运行错误: %v\n", err)
		}
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = s.shutdown(shutdownCtx)
	return nil
}

func (s *DebugServer) shutdown(ctx context.Context) error {
	var errs []error
	if s.pollHTTPServer != nil {
		if err := s.pollHTTPServer.Shutdown(ctx); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs = append(errs, err)
		}
	}
	if s.proxyHTTPServer != nil {
		if err := s.proxyHTTPServer.Shutdown(ctx); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs = append(errs, err)
		}
	}
	if s.wsHTTPServer != nil {
		if err := s.wsHTTPServer.Shutdown(ctx); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs = append(errs, err)
		}
	}

	if len(errs) == 0 {
		return nil
	}
	return fmt.Errorf("关闭服务失败: %v", errs)
}

func (s *DebugServer) startHTTPServers() {
	pollMux := http.NewServeMux()
	pollMux.HandleFunc("/ping", s.handleHTTPPing)
	pollMux.HandleFunc("/poll", s.handleHTTPPoll)
	pollMux.HandleFunc("/response", s.handleHTTPResponse)
	pollMux.HandleFunc("/fetch_file", s.handleHTTPFetchFile)
	pollMux.HandleFunc("/", s.handleHTTPPing)

	s.pollHTTPServer = &http.Server{
		Addr:    fmt.Sprintf("%s:%d", s.host, s.httpPort),
		Handler: pollMux,
	}

	go func() {
		if err := s.pollHTTPServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Printf("\n[ERROR] HTTP 轮询服务器启动失败: %v\n", err)
		}
	}()

	proxyMux := http.NewServeMux()
	proxyMux.HandleFunc("/v1/chat/completions", s.handleOpenAIProxy)
	proxyMux.HandleFunc("/", s.handleOpenAIPing)

	s.proxyHTTPServer = &http.Server{
		Addr:    fmt.Sprintf("%s:%d", s.host, s.proxyPort),
		Handler: proxyMux,
	}

	go func() {
		if err := s.proxyHTTPServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Printf("\n[ERROR] HTTP 代理服务器启动失败: %v\n", err)
		}
	}()
}

func (s *DebugServer) startWebSocketServer() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleWebSocketUpgrade)

	s.wsHTTPServer = &http.Server{
		Addr:    fmt.Sprintf("%s:%d", s.host, s.wsPort),
		Handler: mux,
	}

	go func() {
		if err := s.wsHTTPServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			fmt.Printf("\n[ERROR] WebSocket 服务器启动失败: %v\n", err)
		}
	}()
}

var websocketUpgrader = websocket.Upgrader{
	ReadBufferSize:  1024 * 8,
	WriteBufferSize: 1024 * 8,
	CheckOrigin: func(r *http.Request) bool {
		return true
	},
}

func (s *DebugServer) handleWebSocketUpgrade(w http.ResponseWriter, r *http.Request) {
	conn, err := websocketUpgrader.Upgrade(w, r, nil)
	if err != nil {
		fmt.Printf("[ERROR] WebSocket 升级失败: %v\n", err)
		return
	}

	clientIP := parseRemoteIP(r.RemoteAddr)
	s.setDeviceConnection(conn, fmt.Sprintf("设备 %s", clientIP))
	fmt.Printf("\n✅ 设备已连接 (WebSocket): %s\n", clientIP)

	if debugMode {
		fmt.Println("[DEBUG] 发送 ping 测试...")
	}
	_ = s.sendCommand(map[string]any{"command": "ping"})

	defer func() {
		s.clearDeviceConnection(conn)
		_ = conn.Close()
		if debugMode {
			fmt.Println("[DEBUG] WebSocket 连接已清理")
		}
	}()

	for {
		messageType, payload, readErr := conn.ReadMessage()
		if readErr != nil {
			fmt.Printf("\n🔌 设备断开连接: %s - %v\n", clientIP, readErr)
			return
		}
		if messageType != websocket.TextMessage && messageType != websocket.BinaryMessage {
			continue
		}

		if debugMode {
			printDebugRawMessage(payload)
		}

		var data map[string]any
		if err := unmarshalJSON(payload, &data); err != nil {
			fmt.Printf("[ERROR] JSON 解析失败: %v\n", err)
			continue
		}
		if debugMode {
			fmt.Printf("[DEBUG] 解析JSON: %v\n", mapKeys(data))
		}
		s.handleResponse(data)
	}
}

func (s *DebugServer) handleResponse(data map[string]any) {
	status := asString(data["status"])
	if debugMode {
		fmt.Printf("[DEBUG] 响应状态: %s, 键: %v\n", status, mapKeys(data))
	}

	if status == "ok" {
		s.handleOKResponse(data)
		return
	}
	s.handleErrorResponse(data)
}

func (s *DebugServer) handleOKResponse(data map[string]any) {
	if asBool(data["stream_complete"]) {
		s.handleStreamComplete(data)
		return
	}

	if hasKeys(data, "path", "data", "index") {
		s.setDownloadProgress(asInt(data["index"]), asInt(data["total"]))
		s.saveStreamFile(data)
		return
	}

	if hasKeys(data, "paths", "total") {
		paths := asStringSlice(data["paths"])
		total := asInt(data["total"])
		s.mu.Lock()
		s.compatibleFileList = paths
		s.mu.Unlock()
		fmt.Printf("\n📋 收到文件列表: %d 个文件\n", total)
		s.notifyCompatibleEvent()
		return
	}

	if itemsRaw, ok := data["items"]; ok {
		items := asMapSlice(itemsRaw)
		if debugMode {
			fmt.Printf("[DEBUG] 找到 %d 个项目\n", len(items))
		}
		s.printDirectoryList(items)
		return
	}

	if filesRaw, ok := data["files"]; ok {
		s.saveAllFiles(asMapSlice(filesRaw))
		return
	}

	if hasKeys(data, "data", "path") {
		if s.isCompatibleDownloadInProgress() {
			s.saveCompatibleFile(data)
			s.notifyCompatibleEvent()
		} else {
			s.saveDownloadedFile(data)
		}
		return
	}

	if msg := asString(data["message"]); msg != "" {
		fmt.Printf("\n✅ 成功: %s\n", msg)
	}
}

func (s *DebugServer) handleErrorResponse(data map[string]any) {
	errMsg := asString(data["message"])
	if errMsg == "" {
		errMsg = "未知错误"
	}
	fmt.Printf("\n❌ 错误: %s\n", errMsg)
	if debugMode {
		debugJSON, _ := json.Marshal(data)
		fmt.Printf("[DEBUG] 完整错误数据: %s\n", string(debugJSON))
	}
	if s.isCompatibleDownloadInProgress() {
		s.notifyCompatibleEvent()
	}
}

func (s *DebugServer) handleStreamComplete(data map[string]any) {
	total := asInt(data["total"])
	successCount := asInt(data["success_count"])
	if successCount == 0 && total > 0 {
		successCount = total
	}
	failCount := asInt(data["fail_count"])

	s.mu.RLock()
	savedDir := s.streamBackupDir
	receivedCount := s.downloadFileCount
	s.mu.RUnlock()

	fmt.Printf("\n\n✅ 流式下载完成！\n")
	fmt.Printf("   📊 设备报告: 总计 %d, 成功发送 %d, 失败 %d\n", total, successCount, failCount)
	fmt.Printf("   📥 服务器收到: %d 个文件\n", receivedCount)

	if receivedCount < successCount {
		fmt.Printf("   ⚠️  警告: 有 %d 个文件可能丢失！\n", successCount-receivedCount)
		fmt.Printf("      (设备发送了 %d 个，但只收到 %d 个)\n", successCount, receivedCount)
	} else if receivedCount == successCount && successCount > 0 {
		fmt.Printf("   ✅ 验证通过: 所有文件都已收到\n")
	}

	if savedDir != "" {
		fmt.Printf("💾 保存目录: %s\n", savedDir)
	} else if total > 0 && receivedCount == 0 {
		fmt.Printf("⚠️  警告: 收到完成信号但未收到任何文件数据！\n")
		fmt.Printf("      这可能是网络乱序问题，请重试\n")
	} else {
		fmt.Printf("💾 保存目录: 无文件需要保存\n")
	}

	s.resetStreamDownloadState()
}

func (s *DebugServer) printDirectoryList(items []map[string]any) {
	fmt.Printf("\n📁 目录内容:\n")
	fmt.Printf("%-40s %-10s %-15s %-20s\n", "名称", "类型", "大小", "修改时间")
	fmt.Println(strings.Repeat("-", 90))
	for _, item := range items {
		name := asString(item["name"])
		isDir := asBool(item["isDirectory"])
		typeName := "文件"
		sizeText := "-"
		if isDir {
			typeName = "目录"
		} else {
			sizeText = formatSize(int64(asInt(item["size"])))
		}

		mtimeSec := int64(asFloat64(item["modificationDate"]))
		mtime := time.Unix(mtimeSec, 0).Format("2006-01-02 15:04:05")
		fmt.Printf("%-40s %-10s %-15s %-20s\n", name, typeName, sizeText, mtime)
	}
	fmt.Println()
}

func (s *DebugServer) cleanDevicePath(path string) string {
	if path == "" {
		return path
	}
	if strings.Contains(path, "/Documents/") {
		relative := strings.SplitN(path, "/Documents/", 2)[1]
		if debugMode {
			fmt.Printf("[DEBUG] 路径清理: '%s' -> '%s'\n", path, relative)
		}
		return relative
	}
	if strings.HasSuffix(path, "/Documents") {
		return ""
	}
	if strings.HasPrefix(path, "/private") {
		return strings.TrimPrefix(path, "/private")
	}
	if !strings.HasPrefix(path, "/") {
		return path
	}
	if debugMode {
		fmt.Printf("[DEBUG] 路径清理（移除前导斜杠）: '%s'\n", path)
	}
	return strings.TrimLeft(path, "/")
}

func (s *DebugServer) saveDownloadedFile(data map[string]any) {
	path := asString(data["path"])
	if path == "" {
		path = "download"
	}
	b64Data := asString(data["data"])

	fileData, err := base64.StdEncoding.DecodeString(b64Data)
	if err != nil {
		fmt.Printf("\n❌ 保存文件失败: Base64 解码失败: %v\n", err)
		return
	}

	filename := filepath.Base(path)
	localPath := filepath.Join("downloads", filename)
	if err := os.MkdirAll(filepath.Dir(localPath), 0o755); err != nil {
		fmt.Printf("\n❌ 保存文件失败: %v\n", err)
		return
	}
	if err := os.WriteFile(localPath, fileData, 0o644); err != nil {
		fmt.Printf("\n❌ 保存文件失败: %v\n", err)
		return
	}
	fmt.Printf("\n💾 文件已保存: %s (%s)\n", localPath, formatSize(int64(len(fileData))))
}

func (s *DebugServer) saveAllFiles(files []map[string]any) {
	timestamp := time.Now().Format("20060102_150405")
	backupDir := filepath.Join("downloads", "Documents_backup_"+timestamp)
	if err := os.MkdirAll(backupDir, 0o755); err != nil {
		fmt.Printf("\n❌ 创建备份目录失败: %v\n", err)
		return
	}

	fmt.Printf("\n📦 开始保存 %d 个文件到: %s\n", len(files), backupDir)
	for _, fileInfo := range files {
		path := asString(fileInfo["path"])
		b64Data := asString(fileInfo["data"])
		fileData, err := base64.StdEncoding.DecodeString(b64Data)
		if err != nil {
			fmt.Printf("  ❌ %s: Base64 解码失败: %v\n", path, err)
			continue
		}

		localPath, err := safeJoinRelative(backupDir, path)
		if err != nil {
			fmt.Printf("  ❌ %s: 非法路径: %v\n", path, err)
			continue
		}

		if err := os.MkdirAll(filepath.Dir(localPath), 0o755); err != nil {
			fmt.Printf("  ❌ %s: 创建目录失败: %v\n", path, err)
			continue
		}
		if err := os.WriteFile(localPath, fileData, 0o644); err != nil {
			fmt.Printf("  ❌ %s: 写入失败: %v\n", path, err)
			continue
		}
		fmt.Printf("  ✅ %s (%s)\n", path, formatSize(int64(len(fileData))))
	}
	fmt.Printf("\n💾 全部保存完成: %s\n", backupDir)
}

func (s *DebugServer) saveStreamFile(data map[string]any) {
	path := asString(data["path"])
	b64Data := asString(data["data"])
	index := asInt(data["index"])
	total := asInt(data["total"])
	size := asInt(data["size"])

	if path == "" || b64Data == "" {
		fmt.Printf("  [%d] ⚠️  跳过空文件数据: path=%s, data_len=%d\n", index, path, len(b64Data))
		return
	}

	fileData, err := base64.StdEncoding.DecodeString(b64Data)
	if err != nil {
		fmt.Printf("  [%d] ❌ %s: Base64 解码失败: %v\n", index, path, err)
		return
	}

	streamDir, err := s.ensureStreamBackupDir("Documents_stream")
	if err != nil {
		fmt.Printf("  [%d] ❌ %s: 创建目录失败: %v\n", index, path, err)
		return
	}

	localPath, err := safeJoinRelative(streamDir, path)
	if err != nil {
		fmt.Printf("  [%d] ❌ %s: 非法路径: %v\n", index, path, err)
		return
	}

	if err := os.MkdirAll(filepath.Dir(localPath), 0o755); err != nil {
		fmt.Printf("  [%d] ❌ %s: 创建目录失败: %v\n", index, path, err)
		return
	}
	if err := os.WriteFile(localPath, fileData, 0o644); err != nil {
		fmt.Printf("  [%d] ❌ %s: 写入失败: %v\n", index, path, err)
		return
	}

	s.mu.Lock()
	s.downloadFileCount = index
	s.mu.Unlock()

	progress := fmt.Sprintf("[%d]", index)
	if total > 0 {
		progress = fmt.Sprintf("[%d/%d]", index, total)
	}
	if size <= 0 {
		size = len(fileData)
	}
	fmt.Printf("  %s ✅ %s (%s)\n", progress, path, formatSize(int64(size)))
	if debugMode {
		fmt.Printf("[DEBUG] 已保存: %s\n", localPath)
	}
}

func (s *DebugServer) saveCompatibleFile(data map[string]any) bool {
	path := asString(data["path"])
	b64Data := asString(data["data"])
	size := asInt(data["size"])
	if path == "" || b64Data == "" {
		fmt.Printf("  ⚠️  跳过空文件数据: path=%s\n", path)
		return false
	}

	fileData, err := base64.StdEncoding.DecodeString(b64Data)
	if err != nil {
		fmt.Printf("  ❌ %s: Base64 解码失败: %v\n", path, err)
		return false
	}

	s.mu.RLock()
	backupDir := s.streamBackupDir
	expectedTotal := s.downloadExpectedTotal
	s.mu.RUnlock()

	if backupDir == "" {
		fmt.Printf("  ❌ %s: 兼容模式目录未初始化\n", path)
		return false
	}

	localPath, err := safeJoinRelative(backupDir, path)
	if err != nil {
		fmt.Printf("  ❌ %s: 非法路径: %v\n", path, err)
		return false
	}
	if err := os.MkdirAll(filepath.Dir(localPath), 0o755); err != nil {
		fmt.Printf("  ❌ %s: 创建目录失败: %v\n", path, err)
		return false
	}
	if err := os.WriteFile(localPath, fileData, 0o644); err != nil {
		fmt.Printf("  ❌ %s: 写入失败: %v\n", path, err)
		return false
	}

	s.mu.Lock()
	s.downloadFileCount++
	current := s.downloadFileCount
	s.mu.Unlock()

	if size <= 0 {
		size = len(fileData)
	}
	fmt.Printf("  [%d/%d] ✅ %s (%s)\n", current, expectedTotal, path, formatSize(int64(size)))
	return true
}

func (s *DebugServer) ensureStreamBackupDir(prefix string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.streamBackupDir != "" {
		return s.streamBackupDir, nil
	}
	timestamp := time.Now().Format("20060102_150405")
	dir := filepath.Join("downloads", prefix+"_"+timestamp)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	s.streamBackupDir = dir
	fmt.Printf("\n📦 开始流式接收文件到: %s\n", dir)
	return dir, nil
}

func (s *DebugServer) downloadAllCompatible() {
	timestamp := time.Now().Format("20060102_150405")
	backupDir := filepath.Join("downloads", "Documents_compatible_"+timestamp)
	if err := os.MkdirAll(backupDir, 0o755); err != nil {
		fmt.Printf("❌ 创建下载目录失败: %v\n", err)
		return
	}

	s.mu.Lock()
	s.compatibleDownloadInProgress = true
	s.compatibleFileList = nil
	s.downloadFileCount = 0
	s.downloadExpectedTotal = 0
	s.streamBackupDir = backupDir
	s.compatibleDownloadEvent = make(chan struct{}, 1)
	s.mu.Unlock()

	defer func() {
		s.mu.Lock()
		s.compatibleDownloadInProgress = false
		s.compatibleFileList = nil
		s.compatibleDownloadEvent = nil
		s.streamBackupDir = ""
		s.mu.Unlock()
	}()

	fmt.Println("📋 步骤1: 获取设备文件列表...")
	listEvent := s.newCompatibleEvent()
	_ = s.sendCommand(map[string]any{"command": "list_all"})
	if !waitCompatibleEvent(listEvent, 30*time.Second) {
		fmt.Println("❌ 获取文件列表超时！")
		return
	}

	s.mu.RLock()
	fileList := append([]string(nil), s.compatibleFileList...)
	s.mu.RUnlock()
	if len(fileList) == 0 {
		fmt.Println("❌ 未收到文件列表")
		return
	}

	total := len(fileList)
	s.mu.Lock()
	s.downloadExpectedTotal = total
	s.mu.Unlock()

	fmt.Printf("\n📦 步骤2: 开始逐个下载 %d 个文件到: %s\n", total, backupDir)

	successCount := 0
	failCount := 0
	const maxRetries = 3

	for i, filePath := range fileList {
		cleanPath := s.cleanDevicePath(filePath)
		fileSuccess := false

		for attempt := 0; attempt <= maxRetries; attempt++ {
			if attempt > 0 {
				delay := time.Duration(1<<(attempt-1)) * time.Second
				fmt.Printf("  🔄 [%d/%d] 第%d次重试（等待 %s）: %s\n", i+1, total, attempt, delay, filePath)
				time.Sleep(delay)
			}

			prevCount := s.getDownloadFileCount()
			eventCh := s.newCompatibleEvent()
			_ = s.sendCommand(map[string]any{"command": "download", "path": cleanPath})

			if !waitCompatibleEvent(eventCh, 60*time.Second) {
				if attempt < maxRetries {
					fmt.Printf("  ⚠️  [%d/%d] 第%d次尝试超时: %s\n", i+1, total, attempt+1, filePath)
					continue
				}
				fmt.Printf("  ❌ [%d/%d] 已重试 %d 次，最终失败: %s\n", i+1, total, maxRetries, filePath)
				continue
			}

			if s.getDownloadFileCount() > prevCount {
				fileSuccess = true
				break
			}

			if attempt < maxRetries {
				fmt.Printf("  ⚠️  [%d/%d] 收到响应但文件保存失败，准备重试: %s\n", i+1, total, filePath)
			}
		}

		if fileSuccess {
			successCount++
		} else {
			failCount++
		}
		time.Sleep(100 * time.Millisecond)
	}

	fmt.Printf("\n✅ 兼容模式下载完成！\n")
	fmt.Printf("   📊 总计: %d, 成功: %d, 失败: %d\n", total, successCount, failCount)
	fmt.Printf("💾 保存目录: %s\n", backupDir)
}

func (s *DebugServer) sendCommand(command map[string]any) bool {
	if conn := s.getDeviceConnection(); conn != nil {
		cmdStr, err := json.Marshal(command)
		if err != nil {
			fmt.Printf("[ERROR] 命令序列化失败: %v\n", err)
			return false
		}

		s.wsWriteMu.Lock()
		err = conn.WriteMessage(websocket.TextMessage, cmdStr)
		s.wsWriteMu.Unlock()
		if err == nil {
			if debugMode {
				fmt.Printf("[DEBUG] WS发送命令: %s\n", string(cmdStr))
			} else {
				fmt.Printf("[WS] 📤 发送命令: %s\n", asString(command["command"]))
			}
			return true
		}

		fmt.Printf("[ERROR] 发送命令失败: %v\n", err)
		s.clearDeviceConnection(conn)
	}

	if debugMode {
		fmt.Printf("[DEBUG] HTTP队列命令: %s\n", asString(command["command"]))
	} else {
		fmt.Printf("[HTTP] 📦 队列命令: %s\n", asString(command["command"]))
	}
	s.enqueueCommand(command)
	return true
}

func (s *DebugServer) interactiveMenu(ctx context.Context) error {
	reader := bufio.NewReader(os.Stdin)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		time.Sleep(100 * time.Millisecond)
		isConnected, connectionType := s.getConnectionStatus()
		if !isConnected {
			fmt.Printf("\n⏳ 等待设备连接... (模式: %s)\n", connectionType)
			time.Sleep(5 * time.Second)
			continue
		}

		if s.showTransferProgressIfNeeded() {
			continue
		}

		fmt.Printf("\n%s\n", strings.Repeat("=", 60))
		fmt.Printf("📱 %s - ETOS LLM Studio 调试控制台\n", s.getDeviceName())
		fmt.Printf("🔗 连接模式: %s\n", connectionType)
		if s.getDeviceConnection() == nil {
			fmt.Printf("📦 待发送命令: %d 个\n", s.getCommandQueueSize())
		}
		fmt.Printf("%s\n", strings.Repeat("=", 60))
		fmt.Println("1. 📂 列出设备目录")
		fmt.Println("2. 📥 下载文件（设备→电脑）")
		fmt.Println("3. 📤 上传文件（电脑→设备）")
		fmt.Println("4. 🗑️  删除设备文件/目录")
		fmt.Println("5. 📁 在设备创建目录")
		fmt.Println("6. 📦 一键下载 Documents 目录")
		fmt.Println("7. 📦 一键下载（兼容模式）")
		fmt.Println("8. 🚀 一键上传覆盖 Documents")
		fmt.Println("9. 🔄 刷新连接")
		fmt.Println("0. 🚪 退出")
		fmt.Printf("%s\n", strings.Repeat("=", 60))

		choice, err := readLine(reader, "请选择操作 [0-9]: ")
		if err != nil {
			if errors.Is(err, context.Canceled) {
				return err
			}
			time.Sleep(time.Second)
			continue
		}

		switch choice {
		case "1":
			path, _ := readLine(reader, "设备路径 (留空或输入 . 为 Documents): ")
			if path == "" {
				path = "."
			}
			_ = s.sendCommand(map[string]any{"command": "list", "path": path})
			time.Sleep(time.Second)

		case "2":
			path, _ := readLine(reader, "设备文件路径: ")
			if path != "" {
				_ = s.sendCommand(map[string]any{"command": "download", "path": path})
				if s.getDeviceConnection() != nil {
					time.Sleep(time.Second)
				} else {
					fmt.Println("⏳ 命令已入队，等待设备轮询...")
				}
			}

		case "3":
			localFile, _ := readLine(reader, "本地文件路径: ")
			remotePath, _ := readLine(reader, "设备目标路径: ")
			if localFile == "" || remotePath == "" {
				fmt.Println("❌ 文件不存在或路径为空")
				continue
			}
			data, readErr := os.ReadFile(localFile)
			if readErr != nil {
				fmt.Printf("❌ 文件不存在或读取失败: %v\n", readErr)
				continue
			}
			_ = s.sendCommand(map[string]any{
				"command": "upload",
				"path":    remotePath,
				"data":    base64.StdEncoding.EncodeToString(data),
			})
			time.Sleep(time.Second)

		case "4":
			path, _ := readLine(reader, "要删除的设备路径: ")
			if path == "" {
				continue
			}
			confirm, _ := readLine(reader, fmt.Sprintf("确认删除设备上的 '%s'? (yes/no): ", path))
			if strings.EqualFold(confirm, "yes") {
				_ = s.sendCommand(map[string]any{"command": "delete", "path": path})
				time.Sleep(time.Second)
			}

		case "5":
			path, _ := readLine(reader, "在设备创建目录: ")
			if path != "" {
				_ = s.sendCommand(map[string]any{"command": "mkdir", "path": path})
				time.Sleep(time.Second)
			}

		case "6":
			fmt.Println("📦 准备下载整个 Documents 目录...")
			if s.getDeviceConnection() != nil {
				_ = s.sendCommand(map[string]any{"command": "download_all"})
				fmt.Println("⏳ 等待设备打包和传输（WebSocket模式）...")
				time.Sleep(5 * time.Second)
			} else {
				s.resetStreamDownloadState()
				s.mu.Lock()
				s.downloadInProgress = true
				s.mu.Unlock()
				_ = s.sendCommand(map[string]any{"command": "download_all"})
				fmt.Println("⏳ 命令已队列，等待设备传输文件...")
				fmt.Println("💡 提示：如果长时间没有进度，可能是设备端发送格式有问题")
			}

		case "7":
			fmt.Println("📦 兼容模式：准备下载整个 Documents 目录...")
			fmt.Println("💡 此模式会先获取文件列表，然后逐个请求下载")
			s.downloadAllCompatible()

		case "8":
			localDir, _ := readLine(reader, "本地目录路径 (将覆盖设备 Documents): ")
			if !isDir(localDir) {
				fmt.Println("❌ 目录不存在")
				continue
			}
			confirm, _ := readLine(reader, "⚠️  确认覆盖设备 Documents 目录? 所有数据将被删除! (yes/no): ")
			if !strings.EqualFold(confirm, "yes") {
				continue
			}

			fmt.Println("📦 扫描本地目录...")
			files, err := s.collectLocalFilesForUpload(localDir)
			if err != nil {
				fmt.Printf("❌ 扫描目录失败: %v\n", err)
				continue
			}

			if s.getDeviceConnection() != nil {
				fmt.Printf("\n📤 上传 %d 个文件到设备（批量模式）...\n", len(files))
				_ = s.sendCommand(map[string]any{"command": "upload_all", "files": files})
				fmt.Println("⏳ WebSocket模式：设备正在清空 Documents 并写入文件...")
				time.Sleep(5 * time.Second)
			} else {
				fmt.Printf("\n📤 上传 %d 个文件到设备（流式模式）...\n", len(files))

				uploadMap := make(map[string]string, len(files))
				paths := make([]string, 0, len(files))
				for _, file := range files {
					p := asString(file["path"])
					d := asString(file["data"])
					uploadMap[p] = d
					paths = append(paths, p)
				}

				s.mu.Lock()
				s.uploadFileQueue = uploadMap
				s.uploadInProgress = true
				s.mu.Unlock()

				_ = s.sendCommand(map[string]any{"command": "upload_list", "paths": paths, "total": len(paths)})
				fmt.Printf("✅ 已发送文件列表 (%d 个)\n", len(paths))
				fmt.Println("   设备将主动请求每个文件数据")
			}

		case "9":
			if s.getDeviceConnection() != nil {
				_ = s.sendCommand(map[string]any{"command": "ping"})
				time.Sleep(500 * time.Millisecond)
				fmt.Println("✅ 已发送 ping")
			} else {
				fmt.Println("💡 HTTP模式下无需手动刷新")
			}

		case "0":
			fmt.Println("👋 再见!")
			return nil
		}
	}
}

func (s *DebugServer) collectLocalFilesForUpload(localDir string) ([]map[string]any, error) {
	paths := make([]string, 0, 128)
	err := filepath.WalkDir(localDir, func(path string, d os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(localDir, path)
		if err != nil {
			return err
		}
		paths = append(paths, filepath.ToSlash(rel))
		return nil
	})
	if err != nil {
		return nil, err
	}

	sort.Strings(paths)
	files := make([]map[string]any, 0, len(paths))
	for _, rel := range paths {
		absPath := filepath.Join(localDir, filepath.FromSlash(rel))
		data, err := os.ReadFile(absPath)
		if err != nil {
			return nil, err
		}
		files = append(files, map[string]any{
			"path": rel,
			"data": base64.StdEncoding.EncodeToString(data),
		})
		fmt.Printf("  ➤ %s\n", rel)
	}
	return files, nil
}

func (s *DebugServer) getConnectionStatus() (bool, string) {
	if s.getDeviceConnection() != nil {
		return true, "WebSocket"
	}

	s.mu.RLock()
	lastPoll := s.lastPollTime
	s.mu.RUnlock()
	if !lastPoll.IsZero() {
		if time.Since(lastPoll) < 10*time.Second {
			return true, "HTTP 轮询"
		}
		return false, "HTTP 轮询（已断开）"
	}
	return false, "等待连接"
}

func (s *DebugServer) showTransferProgressIfNeeded() bool {
	s.mu.RLock()
	downloadInProgress := s.downloadInProgress
	downloadCount := s.downloadFileCount
	downloadTotal := s.downloadExpectedTotal
	uploadInProgress := s.uploadInProgress
	uploadRemaining := len(s.uploadFileQueue)
	s.mu.RUnlock()

	if downloadInProgress {
		if downloadTotal > 0 {
			fmt.Printf("\r⏳ 下载中... 已接收 %d/%d 个文件", downloadCount, downloadTotal)
		} else {
			fmt.Printf("\r⏳ 下载中... 已接收 %d 个文件", downloadCount)
		}
		time.Sleep(500 * time.Millisecond)
		return true
	}

	if uploadInProgress {
		fmt.Printf("\r⏳ 上传中... 剩余 %d 个文件", uploadRemaining)
		time.Sleep(500 * time.Millisecond)
		return true
	}

	return false
}

func (s *DebugServer) resetStreamDownloadState() {
	s.mu.Lock()
	s.downloadInProgress = false
	s.streamBackupDir = ""
	s.downloadFileCount = 0
	s.downloadExpectedTotal = 0
	s.mu.Unlock()
}

func (s *DebugServer) setDownloadProgress(count, total int) {
	s.mu.Lock()
	s.downloadFileCount = count
	s.downloadExpectedTotal = total
	s.mu.Unlock()
}

func (s *DebugServer) isCompatibleDownloadInProgress() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.compatibleDownloadInProgress
}

func (s *DebugServer) getDownloadFileCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.downloadFileCount
}

func (s *DebugServer) newCompatibleEvent() chan struct{} {
	ch := make(chan struct{}, 1)
	s.mu.Lock()
	s.compatibleDownloadEvent = ch
	s.mu.Unlock()
	return ch
}

func (s *DebugServer) notifyCompatibleEvent() {
	s.mu.RLock()
	ch := s.compatibleDownloadEvent
	s.mu.RUnlock()
	if ch == nil {
		return
	}
	select {
	case ch <- struct{}{}:
	default:
	}
}

func waitCompatibleEvent(ch chan struct{}, timeout time.Duration) bool {
	if ch == nil {
		return false
	}
	select {
	case <-ch:
		return true
	case <-time.After(timeout):
		return false
	}
}

// ===== HTTP handlers =====

func (s *DebugServer) handleHTTPPing(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "message": "pong", "server": "ETOS Debug Server (Go)"})
}

func (s *DebugServer) handleHTTPPoll(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}

	s.markHTTPPoll(r.RemoteAddr)

	s.mu.Lock()
	uploadComplete := s.uploadInProgress && len(s.uploadFileQueue) == 0
	if uploadComplete {
		s.uploadInProgress = false
	}
	s.mu.Unlock()

	if uploadComplete {
		fmt.Println("[HTTP] ✅ 流式上传完成")
		writeJSON(w, http.StatusOK, map[string]any{"command": "upload_complete"})
		return
	}

	if command, ok := s.dequeueCommand(); ok {
		if debugMode {
			fmt.Printf("[DEBUG] HTTP轮询：返回命令 %s\n", asString(command["command"]))
		} else {
			fmt.Printf("[HTTP] 📤 发送命令: %s\n", asString(command["command"]))
		}
		writeJSON(w, http.StatusOK, command)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"command": "none"})
}

func (s *DebugServer) handleHTTPResponse(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}

	var data map[string]any
	if err := decodeRequestJSON(r, &data); err != nil {
		fmt.Printf("[ERROR] 处理HTTP响应失败: %v\n", err)
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}

	if _, ok := data["stream_complete"]; ok {
		fmt.Printf("[HTTP] 📥 收到完成信号: total=%d\n", asInt(data["total"]))
	} else if hasKeys(data, "path", "index") {
		fmt.Printf("[HTTP] 📥 接收文件 %d/%d: %s\n", asInt(data["index"]), asInt(data["total"]), asString(data["path"]))
	} else if debugMode {
		fmt.Printf("[DEBUG] HTTP响应：%v\n", mapKeys(data))
	}

	s.handleResponse(data)
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
}

func (s *DebugServer) handleHTTPFetchFile(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"status": "error", "message": "仅支持 POST"})
		return
	}

	var req map[string]any
	if err := decodeRequestJSON(r, &req); err != nil {
		fmt.Printf("[ERROR] 处理文件请求失败: %v\n", err)
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": err.Error()})
		return
	}

	path := asString(req["path"])
	if path == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"status": "error", "message": "无效请求"})
		return
	}

	data, remaining, ok := s.popUploadFile(path)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]any{"status": "error", "message": "文件不存在"})
		return
	}

	if debugMode {
		fmt.Printf("[DEBUG] 响应文件请求: %s (剩余 %d)\n", path, remaining)
	} else {
		fmt.Printf("[HTTP] 📤 发送文件: %s (剩余 %d)\n", path, remaining)
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "path": path, "data": data, "remaining": remaining})
}

func (s *DebugServer) handleOpenAIProxy(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "仅支持 POST"})
		return
	}

	var openAIData map[string]any
	if err := decodeRequestJSON(r, &openAIData); err != nil {
		fmt.Printf("❌ 处理 OpenAI 请求失败: %v\n", err)
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}

	_ = s.sendCommand(map[string]any{"command": "openai_capture", "request": openAIData})
	if debugMode {
		fmt.Println("[DEBUG] OpenAI 请求已转发到设备")
	} else {
		fmt.Println("📨 OpenAI 请求已转发到设备")
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"id":      "proxy-capture",
		"object":  "chat.completion",
		"created": time.Now().Unix(),
		"model":   asString(openAIData["model"]),
		"choices": []map[string]any{{
			"index": 0,
			"message": map[string]any{
				"role":    "assistant",
				"content": "",
			},
			"finish_reason": "stop",
		}},
	})
}

func (s *DebugServer) handleOpenAIPing(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":   "ok",
		"message":  "ETOS OpenAI Proxy Server (Go)",
		"endpoint": "/v1/chat/completions",
	})
}

// ===== state helpers =====

func (s *DebugServer) setDeviceConnection(conn *websocket.Conn, name string) {
	s.mu.Lock()
	s.deviceConn = conn
	s.deviceName = name
	s.mu.Unlock()
}

func (s *DebugServer) clearDeviceConnection(conn *websocket.Conn) {
	s.mu.Lock()
	if s.deviceConn == conn {
		s.deviceConn = nil
	}
	s.mu.Unlock()
}

func (s *DebugServer) getDeviceConnection() *websocket.Conn {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.deviceConn
}

func (s *DebugServer) getDeviceName() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.deviceName
}

func (s *DebugServer) enqueueCommand(command map[string]any) {
	s.mu.Lock()
	s.commandQueue = append(s.commandQueue, command)
	s.mu.Unlock()
}

func (s *DebugServer) dequeueCommand() (map[string]any, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.commandQueue) == 0 {
		return nil, false
	}
	cmd := s.commandQueue[0]
	s.commandQueue = s.commandQueue[1:]
	return cmd, true
}

func (s *DebugServer) getCommandQueueSize() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.commandQueue)
}

func (s *DebugServer) markHTTPPoll(remoteAddr string) {
	ip := parseRemoteIP(remoteAddr)
	s.mu.Lock()
	s.lastPollTime = time.Now()
	shouldPrint := s.deviceName == "未知设备"
	if shouldPrint {
		s.deviceName = fmt.Sprintf("设备 %s", ip)
	}
	s.mu.Unlock()

	if shouldPrint {
		fmt.Printf("\n✅ 设备已连接 (HTTP 轮询): %s\n", ip)
	}
}

func (s *DebugServer) popUploadFile(path string) (string, int, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, ok := s.uploadFileQueue[path]
	if !ok {
		return "", len(s.uploadFileQueue), false
	}
	delete(s.uploadFileQueue, path)
	return data, len(s.uploadFileQueue), true
}

// ===== utility =====

func readLine(reader *bufio.Reader, prompt string) (string, error) {
	fmt.Print(prompt)
	line, err := reader.ReadString('\n')
	if err != nil {
		if errors.Is(err, os.ErrClosed) {
			return "", context.Canceled
		}
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			return "", err
		}
		return trimmed, nil
	}
	return strings.TrimSpace(line), nil
}

func decodeRequestJSON(r *http.Request, out any) error {
	defer r.Body.Close()
	decoder := json.NewDecoder(r.Body)
	decoder.UseNumber()
	if err := decoder.Decode(out); err != nil {
		return err
	}
	return nil
}

func unmarshalJSON(data []byte, out any) error {
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.UseNumber()
	return decoder.Decode(out)
}

func writeJSON(w http.ResponseWriter, statusCode int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(statusCode)
	encoder := json.NewEncoder(w)
	encoder.SetEscapeHTML(false)
	_ = encoder.Encode(payload)
}

func safeJoinRelative(baseDir, relative string) (string, error) {
	clean := filepath.Clean(filepath.FromSlash(relative))
	if clean == "." || clean == "" {
		return "", errors.New("空路径")
	}
	if filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", errors.New("路径越界")
	}
	return filepath.Join(baseDir, clean), nil
}

func parseRemoteIP(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return remoteAddr
	}
	return host
}

func formatSize(bytes int64) string {
	value := float64(bytes)
	units := []string{"B", "KB", "MB", "GB", "TB"}
	for _, unit := range units {
		if value < 1024 {
			return fmt.Sprintf("%.1f %s", value, unit)
		}
		value /= 1024
	}
	return fmt.Sprintf("%.1f PB", value)
}

func boolToCN(v bool) string {
	if v {
		return "开启"
	}
	return "关闭"
}

func mapKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func printDebugRawMessage(message []byte) {
	if len(message) > 200 {
		fmt.Printf("[DEBUG] 收到原始消息: %s...\n", string(message[:200]))
		return
	}
	fmt.Printf("[DEBUG] 收到消息: %s\n", string(message))
}

func hasKeys(data map[string]any, keys ...string) bool {
	for _, key := range keys {
		if _, ok := data[key]; !ok {
			return false
		}
	}
	return true
}

func asString(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case json.Number:
		return t.String()
	case nil:
		return ""
	default:
		return fmt.Sprintf("%v", t)
	}
}

func asFloat64(v any) float64 {
	switch t := v.(type) {
	case float64:
		return t
	case float32:
		return float64(t)
	case int:
		return float64(t)
	case int64:
		return float64(t)
	case json.Number:
		f, err := t.Float64()
		if err == nil {
			return f
		}
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(t), 64)
		if err == nil {
			return f
		}
	}
	return 0
}

func asInt(v any) int {
	switch t := v.(type) {
	case int:
		return t
	case int64:
		return int(t)
	case float64:
		return int(t)
	case float32:
		return int(t)
	case json.Number:
		if i, err := t.Int64(); err == nil {
			return int(i)
		}
		if f, err := t.Float64(); err == nil {
			return int(f)
		}
	case string:
		if i, err := strconv.Atoi(strings.TrimSpace(t)); err == nil {
			return i
		}
	}
	return 0
}

func asBool(v any) bool {
	switch t := v.(type) {
	case bool:
		return t
	case string:
		value := strings.TrimSpace(strings.ToLower(t))
		return value == "1" || value == "true" || value == "yes"
	case int:
		return t != 0
	case float64:
		return t != 0
	case json.Number:
		if i, err := t.Int64(); err == nil {
			return i != 0
		}
	}
	return false
}

func asStringSlice(v any) []string {
	switch t := v.(type) {
	case []string:
		return append([]string(nil), t...)
	case []any:
		result := make([]string, 0, len(t))
		for _, item := range t {
			result = append(result, asString(item))
		}
		return result
	default:
		return nil
	}
}

func asMapSlice(v any) []map[string]any {
	switch t := v.(type) {
	case []map[string]any:
		return t
	case []any:
		result := make([]map[string]any, 0, len(t))
		for _, item := range t {
			if m, ok := item.(map[string]any); ok {
				result = append(result, m)
			}
		}
		return result
	default:
		return nil
	}
}

func isDir(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return info.IsDir()
}

func applyDebugModeFromEnv() {
	v := strings.TrimSpace(strings.ToLower(os.Getenv("ETOS_DEBUG_MODE")))
	if v == "" {
		return
	}
	debugMode = !(v == "0" || v == "false" || v == "off" || v == "no")
}

func parsePortsFromArgs(args []string) (int, int, int, error) {
	wsPort := defaultWSPort
	httpPort := defaultHTTPPort
	proxyPort := defaultProxyPort

	if len(args) > 1 {
		v, err := strconv.Atoi(args[1])
		if err != nil {
			return 0, 0, 0, fmt.Errorf("WebSocket 端口无效: %w", err)
		}
		wsPort = v
	}
	if len(args) > 2 {
		v, err := strconv.Atoi(args[2])
		if err != nil {
			return 0, 0, 0, fmt.Errorf("HTTP 轮询端口无效: %w", err)
		}
		httpPort = v
	}
	if len(args) > 3 {
		v, err := strconv.Atoi(args[3])
		if err != nil {
			return 0, 0, 0, fmt.Errorf("HTTP 代理端口无效: %w", err)
		}
		proxyPort = v
	}
	return wsPort, httpPort, proxyPort, nil
}

func main() {
	applyDebugModeFromEnv()

	wsPort, httpPort, proxyPort, err := parsePortsFromArgs(os.Args)
	if err != nil {
		fmt.Printf("❌ %v\n", err)
		os.Exit(1)
	}

	server := NewDebugServer(defaultHost, wsPort, httpPort, proxyPort)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if runErr := server.run(ctx); runErr != nil && !errors.Is(runErr, context.Canceled) {
		fmt.Printf("\n❌ 服务器运行失败: %v\n", runErr)
		os.Exit(1)
	}
	fmt.Println("\n👋 服务器已停止")
}
