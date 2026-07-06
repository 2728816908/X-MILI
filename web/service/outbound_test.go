package service

import "testing"

func TestCreateTestConfigDoesNotMutateOutbounds(t *testing.T) {
	outbound := map[string]any{
		"tag":      "warp",
		"protocol": "wireguard",
		"settings": map[string]any{
			"noKernelTun": false,
		},
	}

	(&OutboundService{}).createTestConfig("warp", []any{outbound}, 19080)

	settings := outbound["settings"].(map[string]any)
	if settings["noKernelTun"] != false {
		t.Fatalf("createTestConfig mutated outbound settings: %+v", settings)
	}
}
