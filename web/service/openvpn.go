package service

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/mhsanaei/3x-ui/v2/config"
)

const (
	vpnGateOutboundTag = "vpngate"
	vpnGateRouteTable  = "10077"
)

type OpenVPNService struct{}

type OpenVPNStatus struct {
	Phase    string         `json:"phase"`
	Progress int            `json:"progress"`
	Message  string         `json:"message"`
	Error    string         `json:"error,omitempty"`
	TunIP    string         `json:"tunIP,omitempty"`
	TunDev   string         `json:"tunDev,omitempty"`
	Outbound map[string]any `json:"outbound,omitempty"`
	Server   *VPNGateServer `json:"server,omitempty"`
	Log      []string       `json:"log,omitempty"`
}

type openVPNTask struct {
	sync.Mutex
	id     int64
	cancel context.CancelFunc
	cmd    *exec.Cmd
	status OpenVPNStatus
}

var vpnGateOpenVPN = &openVPNTask{
	status: OpenVPNStatus{
		Phase:    "idle",
		Progress: 0,
		Message:  "未连接",
	},
}

func (s *OpenVPNService) StartVPNGate(server VPNGateServer) (*OpenVPNStatus, error) {
	if server.OpenVPNConfig == "" {
		return nil, errors.New("OpenVPN config is empty")
	}
	ctx, cancel := context.WithCancel(context.Background())

	vpnGateOpenVPN.Lock()
	vpnGateOpenVPN.stopLocked()
	vpnGateOpenVPN.id++
	taskID := vpnGateOpenVPN.id
	vpnGateOpenVPN.cancel = cancel
	vpnGateOpenVPN.status = OpenVPNStatus{
		Phase:    "installing",
		Progress: 8,
		Message:  "正在检查 OpenVPN",
		Server:   &server,
	}
	vpnGateOpenVPN.Unlock()

	go s.connectVPNGate(ctx, taskID, server)
	status := s.VPNGateStatus()
	return &status, nil
}

func (s *OpenVPNService) VPNGateStatus() OpenVPNStatus {
	vpnGateOpenVPN.Lock()
	defer vpnGateOpenVPN.Unlock()
	return cloneOpenVPNStatus(vpnGateOpenVPN.status)
}

func (s *OpenVPNService) CancelVPNGate() OpenVPNStatus {
	vpnGateOpenVPN.Lock()
	defer vpnGateOpenVPN.Unlock()
	vpnGateOpenVPN.stopLocked()
	vpnGateOpenVPN.status.Phase = "canceled"
	vpnGateOpenVPN.status.Progress = 0
	vpnGateOpenVPN.status.Message = "已取消"
	vpnGateOpenVPN.status.Error = ""
	vpnGateOpenVPN.status.TunIP = ""
	vpnGateOpenVPN.status.TunDev = ""
	vpnGateOpenVPN.status.Outbound = nil
	return cloneOpenVPNStatus(vpnGateOpenVPN.status)
}

func (s *OpenVPNService) StopVPNGate() OpenVPNStatus {
	return s.CancelVPNGate()
}

func (s *OpenVPNService) connectVPNGate(ctx context.Context, taskID int64, server VPNGateServer) {
	if runtime.GOOS != "linux" {
		vpnGateOpenVPN.fail(taskID, "OpenVPN 托管连接仅支持 Linux")
		return
	}
	if err := ensureOpenVPNInstalled(ctx, taskID); err != nil {
		vpnGateOpenVPN.fail(taskID, err.Error())
		return
	}

	vpnGateOpenVPN.setTask(taskID, "preparing", 30, "正在清洗配置")
	ovpn, err := sanitizeVPNGateOpenVPNConfig(server.OpenVPNConfig)
	if err != nil {
		vpnGateOpenVPN.fail(taskID, err.Error())
		return
	}
	workDir := filepath.Join(config.GetBinFolderPath(), "vpngate")
	if err := os.MkdirAll(workDir, 0o700); err != nil {
		vpnGateOpenVPN.fail(taskID, err.Error())
		return
	}
	configPath := filepath.Join(workDir, "active.ovpn")
	if err := os.WriteFile(configPath, []byte(ovpn), 0o600); err != nil {
		vpnGateOpenVPN.fail(taskID, err.Error())
		return
	}
	beforeTun, err := listOpenVPNTun()
	if err != nil {
		vpnGateOpenVPN.fail(taskID, err.Error())
		return
	}

	vpnGateOpenVPN.setTask(taskID, "connecting", 45, "正在尝试连接")
	cmd := exec.CommandContext(ctx, "openvpn", "--config", configPath, "--route-nopull", "--auth-nocache", "--verb", "3")
	writer := &openVPNLogWriter{}
	cmd.Stdout = writer
	cmd.Stderr = writer
	if err := cmd.Start(); err != nil {
		vpnGateOpenVPN.fail(taskID, err.Error())
		return
	}
	vpnGateOpenVPN.Lock()
	if vpnGateOpenVPN.id != taskID {
		vpnGateOpenVPN.Unlock()
		_ = cmd.Process.Kill()
		return
	}
	vpnGateOpenVPN.cmd = cmd
	vpnGateOpenVPN.Unlock()

	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	deadline := time.After(45 * time.Second)
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			vpnGateOpenVPN.setTask(taskID, "canceled", 0, "已取消")
			return
		case err := <-done:
			if err == nil {
				vpnGateOpenVPN.fail(taskID, "OpenVPN 已退出")
			} else {
				vpnGateOpenVPN.fail(taskID, err.Error())
			}
			return
		case <-deadline:
			vpnGateOpenVPN.fail(taskID, "OpenVPN 连接超时")
			return
		case <-ticker.C:
			vpnGateOpenVPN.appendLog(writer.lines())
			if writer.contains("Initialization Sequence Completed") {
				tunIP, tunDev, err := detectOpenVPNTun(beforeTun)
				if err != nil {
					vpnGateOpenVPN.fail(taskID, err.Error())
					return
				}
				if err := setupOpenVPNPolicyRoute(tunIP, tunDev); err != nil {
					vpnGateOpenVPN.fail(taskID, err.Error())
					return
				}
				outbound := buildVPNGateOutbound(tunIP)
				vpnGateOpenVPN.Lock()
				if vpnGateOpenVPN.id != taskID {
					vpnGateOpenVPN.Unlock()
					return
				}
				vpnGateOpenVPN.status.Phase = "connected"
				vpnGateOpenVPN.status.Progress = 100
				vpnGateOpenVPN.status.Message = "连接成功"
				vpnGateOpenVPN.status.TunIP = tunIP
				vpnGateOpenVPN.status.TunDev = tunDev
				vpnGateOpenVPN.status.Outbound = outbound
				vpnGateOpenVPN.Unlock()
				go func() {
					if err := <-done; err != nil {
						vpnGateOpenVPN.fail(taskID, "OpenVPN 已断开: "+err.Error())
					}
				}()
				return
			}
			if writer.contains("AUTH_FAILED") {
				vpnGateOpenVPN.fail(taskID, "OpenVPN 认证失败")
				return
			}
		}
	}
}

func sanitizeVPNGateOpenVPNConfig(base64Config string) (string, error) {
	decoded, err := base64.StdEncoding.DecodeString(base64Config)
	if err != nil {
		return "", err
	}
	blocked := map[string]bool{
		"askpass":               true,
		"auth-user-pass-verify": true,
		"cd":                    true,
		"client-connect":        true,
		"client-disconnect":     true,
		"daemon":                true,
		"down":                  true,
		"ipchange":              true,
		"learn-address":         true,
		"log":                   true,
		"log-append":            true,
		"management":            true,
		"plugin":                true,
		"route-pre-down":        true,
		"route-up":              true,
		"script-security":       true,
		"status":                true,
		"tls-verify":            true,
		"up":                    true,
		"writepid":              true,
	}

	var out []string
	inInline := false
	scanner := bufio.NewScanner(bytes.NewReader(decoded))
	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)
		lower := strings.ToLower(trimmed)
		if strings.HasPrefix(lower, "<") {
			inInline = !strings.HasPrefix(lower, "</")
			out = append(out, line)
			continue
		}
		if strings.HasPrefix(lower, "</") {
			inInline = false
			out = append(out, line)
			continue
		}
		if inInline || trimmed == "" || strings.HasPrefix(trimmed, "#") || strings.HasPrefix(trimmed, ";") {
			out = append(out, line)
			continue
		}
		name := strings.ToLower(strings.Fields(trimmed)[0])
		if blocked[name] {
			continue
		}
		if name == "route-nopull" {
			continue
		}
		out = append(out, line)
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	out = append(out, "route-nopull")
	return strings.Join(out, "\n") + "\n", nil
}

func ensureOpenVPNInstalled(ctx context.Context, taskID int64) error {
	if _, err := exec.LookPath("openvpn"); err == nil {
		vpnGateOpenVPN.setTask(taskID, "installing", 20, "OpenVPN 已安装")
		return nil
	}
	vpnGateOpenVPN.setTask(taskID, "installing", 12, "正在安装 OpenVPN")
	switch {
	case commandExists("apt-get"):
		if err := runCommand(ctx, "apt-get", "update"); err != nil {
			return err
		}
		return runCommand(ctx, "apt-get", "install", "-y", "openvpn")
	case commandExists("dnf"):
		return runCommand(ctx, "dnf", "install", "-y", "openvpn")
	case commandExists("yum"):
		return runCommand(ctx, "yum", "install", "-y", "openvpn")
	case commandExists("apk"):
		return runCommand(ctx, "apk", "add", "--no-cache", "openvpn")
	case commandExists("pacman"):
		return runCommand(ctx, "pacman", "-Sy", "--noconfirm", "openvpn")
	default:
		return errors.New("未找到支持的包管理器，请手动安装 openvpn")
	}
}

func commandExists(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

func runCommand(ctx context.Context, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.CombinedOutput()
	vpnGateOpenVPN.addLog(strings.TrimSpace(string(out)))
	if err != nil {
		return fmt.Errorf("%s %s failed: %w", name, strings.Join(args, " "), err)
	}
	return nil
}

func listOpenVPNTun() (map[string]string, error) {
	out, err := exec.Command("ip", "-o", "-4", "addr", "show", "scope", "global").Output()
	if err != nil {
		return nil, err
	}
	tuns := map[string]string{}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		dev := strings.TrimSuffix(fields[1], ":")
		if !strings.HasPrefix(dev, "tun") && !strings.HasPrefix(dev, "tap") {
			continue
		}
		ip, _, err := net.ParseCIDR(fields[3])
		if err == nil && ip.To4() != nil {
			tuns[dev] = ip.String()
		}
	}
	return tuns, nil
}

func detectOpenVPNTun(before map[string]string) (string, string, error) {
	var lastErr error
	for i := 0; i < 12; i++ {
		after, err := listOpenVPNTun()
		if err != nil {
			lastErr = err
		} else if ip, dev, ok := chooseOpenVPNTun(before, after); ok {
			return ip, dev, nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	if lastErr != nil {
		return "", "", lastErr
	}
	return "", "", errors.New("未找到 OpenVPN tun IPv4 地址")
}

func chooseOpenVPNTun(before, after map[string]string) (string, string, bool) {
	for dev, ip := range after {
		if oldIP, ok := before[dev]; !ok || oldIP != ip {
			return ip, dev, true
		}
	}
	if len(after) == 1 {
		for dev, ip := range after {
			return ip, dev, true
		}
	}
	return "", "", false
}

func setupOpenVPNPolicyRoute(tunIP, tunDev string) error {
	_ = runCommand(context.Background(), "ip", "rule", "del", "from", tunIP, "table", vpnGateRouteTable)
	if err := runCommand(context.Background(), "ip", "route", "replace", "default", "dev", tunDev, "table", vpnGateRouteTable); err != nil {
		return err
	}
	if err := runCommand(context.Background(), "ip", "rule", "add", "from", tunIP, "table", vpnGateRouteTable); err != nil {
		return err
	}
	_ = runCommand(context.Background(), "ip", "route", "flush", "cache")
	return nil
}

func cleanupOpenVPNPolicyRoute(tunIP string) {
	if tunIP == "" {
		return
	}
	_ = runCommandQuiet(context.Background(), "ip", "rule", "del", "from", tunIP, "table", vpnGateRouteTable)
	_ = runCommandQuiet(context.Background(), "ip", "route", "flush", "table", vpnGateRouteTable)
	_ = runCommandQuiet(context.Background(), "ip", "route", "flush", "cache")
}

func runCommandQuiet(ctx context.Context, name string, args ...string) error {
	return exec.CommandContext(ctx, name, args...).Run()
}

func buildVPNGateOutbound(tunIP string) map[string]any {
	return map[string]any{
		"tag":         vpnGateOutboundTag,
		"protocol":    "freedom",
		"sendThrough": tunIP,
		"settings": map[string]any{
			"domainStrategy": "UseIP",
		},
	}
}

func (t *openVPNTask) setTask(taskID int64, phase string, progress int, message string) {
	t.Lock()
	defer t.Unlock()
	if t.id != taskID {
		return
	}
	t.status.Phase = phase
	t.status.Progress = progress
	t.status.Message = message
	t.status.Error = ""
}

func (t *openVPNTask) fail(taskID int64, message string) {
	t.Lock()
	defer t.Unlock()
	if t.id != taskID || t.status.Phase == "canceled" {
		return
	}
	t.stopLocked()
	t.status.Phase = "failed"
	t.status.Progress = 0
	t.status.Message = message
	t.status.Error = message
	t.status.Outbound = nil
}

func (t *openVPNTask) stopLocked() {
	if t.cancel != nil {
		t.cancel()
		t.cancel = nil
	}
	if t.cmd != nil && t.cmd.Process != nil {
		_ = t.cmd.Process.Kill()
		t.cmd = nil
	}
	cleanupOpenVPNPolicyRoute(t.status.TunIP)
}

func (t *openVPNTask) addLog(line string) {
	if line == "" {
		return
	}
	t.Lock()
	defer t.Unlock()
	t.status.Log = append(t.status.Log, line)
	if len(t.status.Log) > 80 {
		t.status.Log = t.status.Log[len(t.status.Log)-80:]
	}
}

func (t *openVPNTask) appendLog(lines []string) {
	for _, line := range lines {
		t.addLog(line)
	}
}

func cloneOpenVPNStatus(status OpenVPNStatus) OpenVPNStatus {
	status.Log = append([]string(nil), status.Log...)
	if status.Outbound != nil {
		raw, _ := json.Marshal(status.Outbound)
		var clone map[string]any
		_ = json.Unmarshal(raw, &clone)
		status.Outbound = clone
	}
	if status.Server != nil {
		server := *status.Server
		status.Server = &server
	}
	return status
}

type openVPNLogWriter struct {
	sync.Mutex
	buf      string
	linesBuf []string
	all      string
}

func (w *openVPNLogWriter) Write(p []byte) (int, error) {
	w.Lock()
	defer w.Unlock()
	w.buf += string(p)
	for {
		i := strings.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		line := strings.TrimSpace(w.buf[:i])
		w.buf = w.buf[i+1:]
		if line != "" {
			w.linesBuf = append(w.linesBuf, line)
			w.all += line + "\n"
		}
	}
	return len(p), nil
}

func (w *openVPNLogWriter) lines() []string {
	w.Lock()
	defer w.Unlock()
	lines := append([]string(nil), w.linesBuf...)
	w.linesBuf = nil
	return lines
}

func (w *openVPNLogWriter) contains(text string) bool {
	w.Lock()
	defer w.Unlock()
	return strings.Contains(w.all, text)
}
