package service

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/util/common"
	"golang.org/x/crypto/curve25519"
)

// WarpService provides business logic for Cloudflare WARP integration.
// It manages WARP configuration and connectivity settings.
type WarpService struct {
	SettingService
}

var (
	warpMonitorMu sync.Mutex
	// ponytail: global lock is enough; split per managed outbound if writes become hot.
	managedOutboundMu sync.Mutex
	// ponytail: debounce post-restart checks; per-tag scheduling if restarts get noisy.
	managedRecoveryMu        sync.Mutex
	managedRecoveryScheduled bool
)

func scheduleManagedOutboundRecovery() {
	managedRecoveryMu.Lock()
	if managedRecoveryScheduled {
		managedRecoveryMu.Unlock()
		return
	}
	managedRecoveryScheduled = true
	managedRecoveryMu.Unlock()

	go func() {
		defer func() {
			managedRecoveryMu.Lock()
			managedRecoveryScheduled = false
			managedRecoveryMu.Unlock()
		}()
		time.Sleep(3 * time.Second)
		(&OpenVPNService{}).RecoverStaleVPNGateOutbound()
		(&WarpService{}).CheckAndRepairWarp()
	}()
}

func (s *WarpService) GetWarpData() (string, error) {
	warp, err := s.SettingService.GetWarp()
	if err != nil {
		return "", err
	}
	return warp, nil
}

func (s *WarpService) DelWarpData() error {
	err := s.SettingService.SetWarp("")
	if err != nil {
		return err
	}
	return nil
}

func (s *WarpService) GetWarpConfig() (string, error) {
	var warpData map[string]string
	warp, err := s.SettingService.GetWarp()
	if err != nil {
		return "", err
	}
	err = json.Unmarshal([]byte(warp), &warpData)
	if err != nil {
		return "", err
	}

	url := fmt.Sprintf("https://api.cloudflareclient.com/v0a2158/reg/%s", warpData["device_id"])

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+warpData["access_token"])

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	buffer := &bytes.Buffer{}
	_, err = buffer.ReadFrom(resp.Body)
	if err != nil {
		return "", err
	}

	return buffer.String(), nil
}

func (s *WarpService) RegWarp(secretKey string, publicKey string) (string, error) {
	result, _, _, err := s.registerWarp(secretKey, publicKey, true)
	return result, err
}

func (s *WarpService) registerWarp(secretKey string, publicKey string, save bool) (string, map[string]string, map[string]any, error) {
	tos := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	hostName, _ := os.Hostname()
	data := fmt.Sprintf(`{"key":"%s","tos":"%s","type": "PC","model": "x-ui", "name": "%s"}`, publicKey, tos, hostName)

	url := "https://api.cloudflareclient.com/v0a2158/reg"

	req, err := http.NewRequest("POST", url, bytes.NewBuffer([]byte(data)))
	if err != nil {
		return "", nil, nil, err
	}

	req.Header.Add("CF-Client-Version", "a-7.21-0721")
	req.Header.Add("Content-Type", "application/json")

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", nil, nil, err
	}
	defer resp.Body.Close()
	buffer := &bytes.Buffer{}
	_, err = buffer.ReadFrom(resp.Body)
	if err != nil {
		return "", nil, nil, err
	}

	var rspData map[string]any
	err = json.Unmarshal(buffer.Bytes(), &rspData)
	if err != nil {
		return "", nil, nil, err
	}

	deviceId, ok := rspData["id"].(string)
	if !ok || deviceId == "" {
		return "", nil, nil, common.NewError("invalid WARP response: missing device id")
	}
	token, ok := rspData["token"].(string)
	if !ok || token == "" {
		return "", nil, nil, common.NewError("invalid WARP response: missing token")
	}
	account, ok := rspData["account"].(map[string]any)
	if !ok {
		return "", nil, nil, common.NewError("invalid WARP response: missing account")
	}
	license, ok := account["license"].(string)
	if !ok {
		logger.Debug("Error accessing license value.")
		return "", nil, nil, common.NewError("invalid WARP response: missing license")
	}

	warpData := map[string]string{
		"access_token": token,
		"device_id":    deviceId,
		"license_key":  license,
		"private_key":  secretKey,
	}
	warpDataJSON, err := json.MarshalIndent(warpData, "", "  ")
	if err != nil {
		return "", nil, nil, err
	}
	if save {
		if err := s.SettingService.SetWarp(string(warpDataJSON)); err != nil {
			return "", nil, nil, err
		}
	}

	result, err := json.Marshal(map[string]any{
		"data":   warpData,
		"config": rspData,
	})
	if err != nil {
		return "", nil, nil, err
	}

	return string(result), warpData, rspData, nil
}

func (s *WarpService) SetWarpLicense(license string) (string, error) {
	var warpData map[string]string
	warp, err := s.SettingService.GetWarp()
	if err != nil {
		return "", err
	}
	err = json.Unmarshal([]byte(warp), &warpData)
	if err != nil {
		return "", err
	}

	url := fmt.Sprintf("https://api.cloudflareclient.com/v0a2158/reg/%s/account", warpData["device_id"])
	data := fmt.Sprintf(`{"license": "%s"}`, license)

	req, err := http.NewRequest("PUT", url, bytes.NewBuffer([]byte(data)))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+warpData["access_token"])

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	buffer := &bytes.Buffer{}
	_, err = buffer.ReadFrom(resp.Body)
	if err != nil {
		return "", err
	}

	var response map[string]any
	err = json.Unmarshal(buffer.Bytes(), &response)
	if err != nil {
		return "", err
	}
	if response["success"] == false {
		errorArr, _ := response["errors"].([]any)
		if len(errorArr) > 0 {
			if errorObj, ok := errorArr[0].(map[string]any); ok {
				return "", common.NewError(errorObj["code"], errorObj["message"])
			}
		}
		return "", common.NewError("WARP license update failed")
	}

	warpData["license_key"] = license
	newWarpData, err := json.MarshalIndent(warpData, "", "  ")
	if err != nil {
		return "", err
	}
	if err := s.SettingService.SetWarp(string(newWarpData)); err != nil {
		return "", err
	}

	return string(newWarpData), nil
}

func (s *WarpService) CheckAndRepairWarp() {
	warpMonitorMu.Lock()
	defer warpMonitorMu.Unlock()
	if err := s.checkAndRepairWarpLocked(false); err != nil {
		logger.Warningf("[WARP] Monitor failed: %v", err)
	}
}

func (s *WarpService) RepairWarp() {
	warpMonitorMu.Lock()
	defer warpMonitorMu.Unlock()
	if err := s.checkAndRepairWarpLocked(true); err != nil {
		logger.Warningf("[WARP] Repair failed: %v", err)
	}
}

func (s *WarpService) checkAndRepairWarpLocked(force bool) error {
	configMap, outbounds, current, err := loadWarpXrayConfig()
	if err != nil {
		return err
	}

	if current == nil {
		if !xrayReferencesOutbound(configMap, "warp") {
			return nil
		}
		logger.Warning("[WARP] Recovering missing outbound referenced by routing rules")
	} else if !force {
		if ok, msg := s.testWarpOutbound(current, outbounds); ok {
			logger.Debugf("[WARP] Monitor check passed: %s", msg)
			return nil
		} else if strings.Contains(msg, "Another outbound test") {
			logger.Infof("[WARP] Monitor skipped: %s", msg)
			return nil
		} else {
			logger.Warningf("[WARP] Current node failed, trying replacement: %s", msg)
		}
	} else {
		logger.Warning("[WARP] Outbound test failed, trying replacement")
	}

	var lastErr string
	for i := 1; i <= 10; i++ {
		privateKey, publicKey, err := generateWarpKeypair()
		if err != nil {
			lastErr = err.Error()
			continue
		}
		_, warpData, warpConfig, err := s.registerWarp(privateKey, publicKey, false)
		if err != nil {
			lastErr = err.Error()
			continue
		}
		candidate, err := buildWarpOutbound(warpData, warpConfig)
		if err != nil {
			lastErr = err.Error()
			continue
		}
		nextOutbounds := replaceOutboundByTag(outbounds, "warp", candidate)
		if ok, msg := s.testWarpOutbound(candidate, nextOutbounds); ok {
			if err := saveWarpReplacement(candidate, warpData); err != nil {
				return err
			}
			logger.Infof("[WARP] Replaced unusable node after %d attempt(s): %s", i, msg)
			return nil
		} else {
			lastErr = msg
		}
	}
	return common.NewErrorf("连续更换 10 次仍不可用，已停止本轮 WARP 自动更换: %s", lastErr)
}

func xrayReferencesOutbound(configMap map[string]any, tag string) bool {
	routing, ok := configMap["routing"].(map[string]any)
	if !ok {
		return false
	}
	rules, ok := routing["rules"].([]any)
	if !ok {
		return false
	}
	for _, rule := range rules {
		ruleMap, ok := rule.(map[string]any)
		if ok && ruleMap["outboundTag"] == tag {
			return true
		}
	}
	return false
}

func (s *WarpService) testWarpOutbound(outbound map[string]any, outbounds []any) (bool, string) {
	outboundJSON, _ := json.Marshal(outbound)
	allOutboundsJSON, _ := json.Marshal(outbounds)
	testURL, _ := s.SettingService.GetXrayOutboundTestUrl()
	result, err := (&OutboundService{}).TestOutbound(string(outboundJSON), testURL, string(allOutboundsJSON))
	if err != nil {
		return false, err.Error()
	}
	if result == nil {
		return false, "empty test result"
	}
	if result.Success {
		return true, fmt.Sprintf("%dms", result.Delay)
	}
	return false, result.Error
}

func generateWarpKeypair() (string, string, error) {
	privateKey := make([]byte, 32)
	if _, err := rand.Read(privateKey); err != nil {
		return "", "", err
	}
	privateKey[0] &= 248
	privateKey[31] = (privateKey[31] & 127) | 64
	publicKey, err := curve25519.X25519(privateKey, curve25519.Basepoint)
	if err != nil {
		return "", "", err
	}
	return base64.StdEncoding.EncodeToString(privateKey), base64.StdEncoding.EncodeToString(publicKey), nil
}

func loadWarpXrayConfig() (map[string]any, []any, map[string]any, error) {
	templateConfig, err := (&SettingService{}).GetXrayConfigTemplate()
	if err != nil {
		return nil, nil, nil, err
	}
	var configMap map[string]any
	if err := json.Unmarshal([]byte(UnwrapXrayTemplateConfig(templateConfig)), &configMap); err != nil {
		return nil, nil, nil, err
	}
	outbounds, _ := configMap["outbounds"].([]any)
	for _, outbound := range outbounds {
		outboundMap, ok := outbound.(map[string]any)
		if !ok {
			continue
		}
		if outboundMap["tag"] == "warp" {
			return configMap, outbounds, outboundMap, nil
		}
	}
	return configMap, outbounds, nil, nil
}

func buildWarpOutbound(warpData map[string]string, warpConfig map[string]any) (map[string]any, error) {
	configObj, ok := warpConfig["config"].(map[string]any)
	if !ok {
		return nil, common.NewError("invalid WARP config")
	}
	iface, _ := configObj["interface"].(map[string]any)
	addressesMap, _ := iface["addresses"].(map[string]any)
	addresses := make([]string, 0, 2)
	if v4, _ := addressesMap["v4"].(string); v4 != "" {
		addresses = append(addresses, v4+"/32")
	}
	if v6, _ := addressesMap["v6"].(string); v6 != "" {
		addresses = append(addresses, v6+"/128")
	}
	clientID, _ := configObj["client_id"].(string)
	reservedBytes, err := base64.StdEncoding.DecodeString(clientID)
	if err != nil {
		return nil, err
	}
	reserved := make([]int, len(reservedBytes))
	for i, b := range reservedBytes {
		reserved[i] = int(b)
	}
	peers, _ := configObj["peers"].([]any)
	if len(peers) == 0 {
		return nil, common.NewError("invalid WARP config: missing peer")
	}
	peer, _ := peers[0].(map[string]any)
	endpoint, _ := peer["endpoint"].(map[string]any)
	host, _ := endpoint["host"].(string)
	publicKey, _ := peer["public_key"].(string)
	if host == "" || publicKey == "" {
		return nil, common.NewError("invalid WARP config: missing endpoint")
	}

	return map[string]any{
		"tag":      "warp",
		"protocol": "wireguard",
		"settings": map[string]any{
			"mtu":            1420,
			"secretKey":      warpData["private_key"],
			"address":        addresses,
			"reserved":       reserved,
			"domainStrategy": "ForceIP",
			"peers": []map[string]any{{
				"publicKey": publicKey,
				"endpoint":  host,
			}},
			"noKernelTun": false,
		},
	}, nil
}

func replaceOutboundByTag(outbounds []any, tag string, replacement map[string]any) []any {
	next := append([]any(nil), outbounds...)
	for i, outbound := range next {
		outboundMap, ok := outbound.(map[string]any)
		if ok && outboundMap["tag"] == tag {
			next[i] = replacement
			return next
		}
	}
	return append(next, replacement)
}

func saveWarpReplacement(warpOutbound map[string]any, warpData map[string]string) error {
	warpDataJSON, err := json.MarshalIndent(warpData, "", "  ")
	if err != nil {
		return err
	}

	managedOutboundMu.Lock()
	defer managedOutboundMu.Unlock()

	templateConfig, err := (&SettingService{}).GetXrayConfigTemplate()
	if err != nil {
		return err
	}
	var configMap map[string]any
	if err := json.Unmarshal([]byte(UnwrapXrayTemplateConfig(templateConfig)), &configMap); err != nil {
		return err
	}
	latestOutbounds, _ := configMap["outbounds"].([]any)
	configMap["outbounds"] = replaceOutboundByTag(latestOutbounds, "warp", warpOutbound)
	newConfigBytes, err := json.MarshalIndent(configMap, "", "  ")
	if err != nil {
		return err
	}
	if err := (&XraySettingService{}).SaveXraySetting(string(newConfigBytes)); err != nil {
		return err
	}
	if err := (&SettingService{}).SetWarp(string(warpDataJSON)); err != nil {
		return err
	}
	return (&XrayService{}).RestartXray(true)
}
