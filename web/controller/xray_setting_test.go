package controller

import (
	"encoding/json"
	"testing"
)

func TestSyncManagedOutboundTestConfigUsesLatestTemplateOutbound(t *testing.T) {
	outbound := `{"tag":"warp","protocol":"wireguard","settings":{"secretKey":"old"}}`
	allOutbounds := `[{"tag":"direct","protocol":"freedom"},{"tag":"warp","protocol":"wireguard","settings":{"secretKey":"old"}}]`
	template := `{"outbounds":[{"tag":"warp","protocol":"wireguard","settings":{"secretKey":"new"}},{"tag":"direct","protocol":"freedom"}]}`

	gotOutbound, gotAllOutbounds := syncManagedOutboundTestConfig(outbound, allOutbounds, template)

	var got map[string]any
	if err := json.Unmarshal([]byte(gotOutbound), &got); err != nil {
		t.Fatal(err)
	}
	settings := got["settings"].(map[string]any)
	if settings["secretKey"] != "new" {
		t.Fatalf("outbound was not refreshed: %+v", got)
	}

	var gotAll []map[string]any
	if err := json.Unmarshal([]byte(gotAllOutbounds), &gotAll); err != nil {
		t.Fatal(err)
	}
	if gotAll[0]["tag"] != "direct" {
		t.Fatalf("unrelated outbounds were not preserved: %+v", gotAll)
	}
	settings = gotAll[1]["settings"].(map[string]any)
	if settings["secretKey"] != "new" {
		t.Fatalf("managed outbound was not refreshed in allOutbounds: %+v", gotAll)
	}
}
