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

type providerUpsertInput struct {
	ProviderID      string
	Name            string
	BaseURL         string
	APIFormat       string
	APIKey          string
	HeaderOverrides string
	ProxyMode       string
	ProxyType       string
	ProxyHost       string
	ProxyPort       string
	ProxyUsername   string
	ProxyPassword   string
}

func buildProviderUpsertPayload(input providerUpsertInput) (map[string]any, error) {
	var headers map[string]string
	if strings.TrimSpace(input.HeaderOverrides) != "" {
		if err := json.Unmarshal([]byte(input.HeaderOverrides), &headers); err != nil {
			return nil, fmt.Errorf("Header Overrides 不是合法 JSON 对象: %w", err)
		}
	}
	if headers == nil {
		headers = map[string]string{}
	}

	proxyConfiguration, err := buildProxyConfigurationPayload(input)
	if err != nil {
		return nil, err
	}

	payload := map[string]any{
		"command":             "provider_upsert",
		"name":                strings.TrimSpace(input.Name),
		"base_url":            strings.TrimSpace(input.BaseURL),
		"api_format":          strings.TrimSpace(input.APIFormat),
		"header_overrides":    headers,
		"proxy_configuration": proxyConfiguration,
	}
	if trimmedProviderID := strings.TrimSpace(input.ProviderID); trimmedProviderID != "" {
		payload["provider_id"] = trimmedProviderID
	}
	if strings.TrimSpace(input.APIKey) != "" {
		payload["api_key"] = input.APIKey
	}
	return payload, nil
}

func buildProxyConfigurationPayload(input providerUpsertInput) (any, error) {
	mode := strings.TrimSpace(strings.ToLower(input.ProxyMode))
	switch mode {
	case "", "inherit":
		return nil, nil
	case "disabled", "disable", "off":
		return map[string]any{
			"isEnabled": false,
			"type":      normalizedProxyType(input.ProxyType),
			"host":      strings.TrimSpace(input.ProxyHost),
			"port":      normalizedProxyPort(input.ProxyPort),
			"username":  strings.TrimSpace(input.ProxyUsername),
			"password":  strings.TrimSpace(input.ProxyPassword),
		}, nil
	case "enabled", "enable", "on":
		host := strings.TrimSpace(input.ProxyHost)
		if host == "" {
			return nil, fmt.Errorf("启用 Provider 代理需要填写主机")
		}
		return map[string]any{
			"isEnabled": true,
			"type":      normalizedProxyType(input.ProxyType),
			"host":      host,
			"port":      normalizedProxyPort(input.ProxyPort),
			"username":  strings.TrimSpace(input.ProxyUsername),
			"password":  strings.TrimSpace(input.ProxyPassword),
		}, nil
	default:
		return nil, fmt.Errorf("代理模式必须是 inherit、disabled 或 enabled")
	}
}

func normalizedProxyType(value string) string {
	switch strings.TrimSpace(strings.ToLower(value)) {
	case "socks5":
		return "socks5"
	default:
		return "http"
	}
}

func normalizedProxyPort(value string) int {
	port := asInt(strings.TrimSpace(value))
	if port < 1 || port > 65535 {
		return 8080
	}
	return port
}

func providerHeaderOverridesText(provider map[string]any) string {
	if value, ok := provider["headerOverrides"]; ok {
		return prettyJSON(value)
	}
	return "{}"
}

func providerProxyMode(provider map[string]any) string {
	proxy, ok := provider["proxyConfiguration"].(map[string]any)
	if !ok {
		return "inherit"
	}
	if asBool(proxy["isEnabled"]) {
		return "enabled"
	}
	return "disabled"
}

func providerProxyField(provider map[string]any, key, fallback string) string {
	proxy, ok := provider["proxyConfiguration"].(map[string]any)
	if !ok {
		return fallback
	}
	value := asString(proxy[key])
	if value == "" {
		return fallback
	}
	return value
}

type providerModelUpsertInput struct {
	ProviderID              string
	ModelID                 string
	ModelName               string
	DisplayName             string
	Kind                    string
	InputModalities         string
	OutputModalities        string
	Capabilities            string
	RequestBodyOverrideMode string
	RawRequestBodyJSON      string
	OverrideParameters      string
	Pricing                 string
	IsActivated             bool
}

func buildProviderModelUpsertPayload(input providerModelUpsertInput) (map[string]any, error) {
	var override map[string]any
	if strings.TrimSpace(input.OverrideParameters) != "" {
		if err := json.Unmarshal([]byte(input.OverrideParameters), &override); err != nil {
			return nil, fmt.Errorf("Override Parameters 不是合法 JSON 对象: %w", err)
		}
	}
	if override == nil {
		override = map[string]any{}
	}

	pricing, err := parseOptionalJSONObject(input.Pricing, "Pricing")
	if err != nil {
		return nil, err
	}

	payload := map[string]any{
		"command":                    "provider_model_upsert",
		"provider_id":                strings.TrimSpace(input.ProviderID),
		"model_name":                 strings.TrimSpace(input.ModelName),
		"display_name":               strings.TrimSpace(input.DisplayName),
		"is_activated":               input.IsActivated,
		"kind":                       strings.TrimSpace(input.Kind),
		"input_modalities":           splitCSV(input.InputModalities),
		"output_modalities":          splitCSV(input.OutputModalities),
		"capabilities":               splitCSV(input.Capabilities),
		"request_body_override_mode": strings.TrimSpace(input.RequestBodyOverrideMode),
		"raw_request_body_json":      strings.TrimSpace(input.RawRequestBodyJSON),
		"override_parameters":        override,
		"pricing":                    pricing,
	}
	if trimmedModelID := strings.TrimSpace(input.ModelID); trimmedModelID != "" {
		payload["model_id"] = trimmedModelID
	}
	return payload, nil
}

func parseOptionalJSONObject(value, title string) (map[string]any, error) {
	var object map[string]any
	if strings.TrimSpace(value) != "" {
		if err := json.Unmarshal([]byte(value), &object); err != nil {
			return nil, fmt.Errorf("%s 不是合法 JSON 对象: %w", title, err)
		}
	}
	if object == nil {
		object = map[string]any{}
	}
	return object, nil
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

func providerModelPricingText(model map[string]any) string {
	if value, ok := model["pricing"]; ok {
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
