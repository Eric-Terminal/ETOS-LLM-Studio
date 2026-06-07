package main

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"time"
)

func joinDevicePath(base, name string) string {
	if base == "" || base == "." {
		return name
	}
	return strings.TrimRight(base, "/") + "/" + name
}

func parentDevicePath(path string) string {
	path = strings.Trim(path, "/")
	if path == "" || path == "." {
		return "."
	}
	parent := filepath.ToSlash(filepath.Dir(path))
	if parent == "." || parent == "/" {
		return "."
	}
	return parent
}

func quoteSQLiteIdentifierForTUI(identifier string) string {
	return `"` + strings.ReplaceAll(identifier, `"`, `""`) + `"`
}

func prettyJSON(value any) string {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return fmt.Sprintf("%v", value)
	}
	return string(data)
}

func previewText(data []byte) string {
	if len(data) == 0 {
		return ""
	}
	if len(data) > 64*1024 {
		data = data[:64*1024]
	}
	text := string(data)
	if strings.ContainsRune(text, '\u0000') {
		return ""
	}
	return text
}

func truncateLine(value string, maxLen int) string {
	value = strings.ReplaceAll(value, "\n", " ")
	if len(value) <= maxLen {
		return value
	}
	return value[:maxLen-1] + "…"
}

func boolLabel(value bool) string {
	if value {
		return "是"
	}
	return "否"
}

func asAnySlice(v any) []any {
	switch t := v.(type) {
	case []any:
		return append([]any(nil), t...)
	case []map[string]any:
		result := make([]any, 0, len(t))
		for _, item := range t {
			result = append(result, item)
		}
		return result
	default:
		return nil
	}
}

func newUUIDLikeString() string {
	now := time.Now().UnixNano()
	return fmt.Sprintf("00000000-0000-4000-8000-%012x", now&0xffffffffffff)
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
