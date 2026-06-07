package main

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
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

func splitCSV(value string) []string {
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		trimmed := strings.TrimSpace(part)
		if trimmed != "" {
			result = append(result, trimmed)
		}
	}
	return result
}

func buildProviderModelUpsertPayload(providerID, modelID, modelName, displayName, kind, capabilities, overrideParameters string, isActivated bool) (map[string]any, error) {
	var override map[string]any
	if strings.TrimSpace(overrideParameters) != "" {
		if err := json.Unmarshal([]byte(overrideParameters), &override); err != nil {
			return nil, fmt.Errorf("Override Parameters 不是合法 JSON 对象: %w", err)
		}
	}
	if override == nil {
		override = map[string]any{}
	}

	payload := map[string]any{
		"command":             "provider_model_upsert",
		"provider_id":         strings.TrimSpace(providerID),
		"model_name":          strings.TrimSpace(modelName),
		"display_name":        strings.TrimSpace(displayName),
		"is_activated":        isActivated,
		"kind":                strings.TrimSpace(kind),
		"capabilities":        splitCSV(capabilities),
		"override_parameters": override,
	}
	if trimmedModelID := strings.TrimSpace(modelID); trimmedModelID != "" {
		payload["model_id"] = trimmedModelID
	}
	return payload, nil
}

func findProviderModelRow(models []map[string]any, modelID string) map[string]any {
	for _, model := range models {
		if asString(model["id"]) == modelID {
			return model
		}
	}
	return map[string]any{}
}

func providerModelOptionLabel(model map[string]any, index int) string {
	name := asString(model["modelName"])
	displayName := asString(model["displayName"])
	if displayName == "" {
		displayName = name
	}
	if name == "" {
		name = asString(model["id"])
	}
	if displayName == name || name == "" {
		return fmt.Sprintf("%d. %s", index+1, displayName)
	}
	return fmt.Sprintf("%d. %s · %s", index+1, displayName, name)
}

func providerModelOverrideText(model map[string]any) string {
	if value, ok := model["overrideParameters"]; ok {
		return prettyJSON(value)
	}
	return "{}"
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

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
