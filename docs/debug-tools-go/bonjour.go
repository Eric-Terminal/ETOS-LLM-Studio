package main

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"

	"github.com/grandcat/zeroconf"
)

const (
	bonjourServiceType   = "_etos-debug._tcp"
	bonjourServiceDomain = "local."
)

func (s *DebugServer) startBonjourAdvertisement() {
	hostname, err := os.Hostname()
	if err != nil {
		hostname = ""
	}

	server, err := zeroconf.Register(
		bonjourInstanceName(hostname),
		bonjourServiceType,
		bonjourServiceDomain,
		s.httpPort,
		s.bonjourTXTRecords(),
		nil,
	)
	if err != nil {
		fmt.Printf("\n[WARN] Bonjour 自动发现发布失败: %v\n", err)
		return
	}

	s.bonjourShutdown = server.Shutdown
}

func bonjourInstanceName(hostname string) string {
	trimmed := strings.TrimSpace(hostname)
	if trimmed == "" {
		return "ETOS Debug"
	}
	return fmt.Sprintf("ETOS Debug %s", trimmed)
}

func (s *DebugServer) bonjourTXTRecords() []string {
	return []string{
		"proto=etos-debug-v1",
		"version=" + version,
		"host=" + localHostName(),
		"http_port=" + strconv.Itoa(s.httpPort),
		"ws_port=" + strconv.Itoa(s.wsPort),
		"proxy_port=" + strconv.Itoa(s.proxyPort),
	}
}

func localHostName() string {
	hostname, err := os.Hostname()
	if err != nil {
		return ""
	}
	trimmed := strings.Trim(strings.TrimSpace(hostname), ".")
	if trimmed == "" || net.ParseIP(trimmed) != nil || strings.HasSuffix(trimmed, ".local") {
		return trimmed
	}
	return trimmed + ".local"
}
