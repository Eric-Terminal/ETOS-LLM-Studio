package main

import "testing"

func TestBuildProviderModelUpsertPayloadForExistingModel(t *testing.T) {
	payload, err := buildProviderModelUpsertPayload(
		" provider-1 ",
		" model-1 ",
		" gpt-test ",
		" GPT Test ",
		" chat ",
		"toolCalling, reasoning",
		`{"temperature":0.2}`,
		false,
	)
	if err != nil {
		t.Fatalf("buildProviderModelUpsertPayload 返回错误: %v", err)
	}

	if payload["command"] != "provider_model_upsert" {
		t.Fatalf("command = %v, want provider_model_upsert", payload["command"])
	}
	if payload["provider_id"] != "provider-1" {
		t.Fatalf("provider_id = %v, want provider-1", payload["provider_id"])
	}
	if payload["model_id"] != "model-1" {
		t.Fatalf("model_id = %v, want model-1", payload["model_id"])
	}
	if payload["model_name"] != "gpt-test" {
		t.Fatalf("model_name = %v, want gpt-test", payload["model_name"])
	}
	if payload["display_name"] != "GPT Test" {
		t.Fatalf("display_name = %v, want GPT Test", payload["display_name"])
	}
	if payload["is_activated"] != false {
		t.Fatalf("is_activated = %v, want false", payload["is_activated"])
	}

	capabilities, ok := payload["capabilities"].([]string)
	if !ok {
		t.Fatalf("capabilities 类型 = %T, want []string", payload["capabilities"])
	}
	if len(capabilities) != 2 || capabilities[0] != "toolCalling" || capabilities[1] != "reasoning" {
		t.Fatalf("capabilities = %#v, want toolCalling/reasoning", capabilities)
	}

	override, ok := payload["override_parameters"].(map[string]any)
	if !ok {
		t.Fatalf("override_parameters 类型 = %T, want map[string]any", payload["override_parameters"])
	}
	if override["temperature"] != 0.2 {
		t.Fatalf("temperature = %v, want 0.2", override["temperature"])
	}
}

func TestBuildProviderModelUpsertPayloadRejectsNonObjectOverride(t *testing.T) {
	if _, err := buildProviderModelUpsertPayload("provider-1", "", "gpt-test", "", "chat", "", `[1,2]`, true); err == nil {
		t.Fatal("err = nil，期望拒绝非对象 Override Parameters")
	}
}

func TestProviderModelOptionLabel(t *testing.T) {
	label := providerModelOptionLabel(map[string]any{
		"id":          "model-1",
		"modelName":   "gpt-test",
		"displayName": "GPT Test",
	}, 2)

	if label != "3. GPT Test · gpt-test" {
		t.Fatalf("label = %q, want %q", label, "3. GPT Test · gpt-test")
	}
}
