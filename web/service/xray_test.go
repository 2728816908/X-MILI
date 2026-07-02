package service

import (
	"encoding/json"
	"testing"
)

func TestNormalizeRealitySettings(t *testing.T) {
	stream := map[string]any{
		"realitySettings": map[string]any{
			"target":      "www.nvidia.com:443",
			"maxTimediff": float64(1000),
			"settings":    map[string]any{"publicKey": "client-only"},
		},
	}

	normalizeRealitySettings(stream)

	reality := stream["realitySettings"].(map[string]any)
	if reality["dest"] != "www.nvidia.com:443" {
		t.Fatalf("dest not migrated: %#v", reality)
	}
	if reality["maxTimeDiff"] != float64(1000) {
		t.Fatalf("maxTimeDiff not migrated: %#v", reality)
	}
	if _, ok := reality["target"]; ok {
		t.Fatalf("target should not reach xray config: %#v", reality)
	}
	if _, ok := reality["settings"]; ok {
		t.Fatalf("client-only settings should not reach xray config: %#v", reality)
	}
}

func TestNormalizeStreamSettingsForXray(t *testing.T) {
	raw := `{
		"security": "reality",
		"externalProxy": [{"dest": "example.com"}],
		"realitySettings": {
			"target": "www.nvidia.com:443",
			"settings": {"publicKey": "client-only"}
		}
	}`

	got, err := normalizeStreamSettingsForXray(raw)
	if err != nil {
		t.Fatal(err)
	}
	stream := map[string]any{}
	if err := json.Unmarshal([]byte(got), &stream); err != nil {
		t.Fatal(err)
	}
	if _, ok := stream["externalProxy"]; ok {
		t.Fatalf("externalProxy should not reach xray config: %#v", stream)
	}
	reality := stream["realitySettings"].(map[string]any)
	if reality["dest"] != "www.nvidia.com:443" {
		t.Fatalf("dest not migrated: %#v", reality)
	}
	if _, ok := reality["settings"]; ok {
		t.Fatalf("client-only settings should not reach xray config: %#v", reality)
	}
}
