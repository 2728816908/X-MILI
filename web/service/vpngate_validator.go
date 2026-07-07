package service

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"regexp"
	"runtime"
	"strconv"
	"time"

	"golang.org/x/net/proxy"
)

type VPNGateValidator struct{}

type vpnGateCheckResult struct {
	index       int
	localPing   int64
	httpLatency int64
	isAlive     bool
}

var vpnGateMSRegex = regexp.MustCompile(`[=<]\s*(\d+)ms|time[=<]\s*(\d+)\.?(\d*)\s*ms`)

func (VPNGateValidator) Validate(servers []VPNGateServer) []VPNGateServer {
	tasks := make(chan int, len(servers))
	results := make(chan vpnGateCheckResult, len(servers))
	workers := 30
	if len(servers) < workers {
		workers = len(servers)
	}
	for i := 0; i < workers; i++ {
		go func() {
			for index := range tasks {
				server := servers[index]
				ping := server.LocalPing
				alive := server.OpenVPNConfig != ""
				if server.Proto == "tcp" && server.Port != "" {
					alive = testVPNGateTCP(server.IP, server.Port)
				}
				if ping < 0 {
					ping = pingVPNGateIP(server.IP)
				}
				if alive && ping < 0 {
					ping = 999999
				}
				httpLat := measureVPNGateHTTPLatency(server.IP)
				results <- vpnGateCheckResult{index: index, localPing: ping, httpLatency: httpLat, isAlive: alive}
			}
		}()
	}
	for i := range servers {
		tasks <- i
	}
	close(tasks)

	checked := make([]vpnGateCheckResult, len(servers))
	for range servers {
		res := <-results
		checked[res.index] = res
	}
	for i, res := range checked {
		servers[i].LocalPing = -1
		servers[i].HttpLatency = -1
		if res.isAlive {
			servers[i].LocalPing = res.localPing
			servers[i].HttpLatency = res.httpLatency
		}
	}
	return servers
}

// warpDial 通过本机 WARP SOCKS5 代理（127.0.0.1:40000）建立连接。
// 若代理不可用则降级为直连，并统一应用 timeout。
func warpDial(network, addr string, timeout time.Duration) (net.Conn, error) {
	dialer, err := proxy.SOCKS5("tcp", "127.0.0.1:40000", nil, proxy.Direct)
	if err != nil {
		return net.DialTimeout(network, addr, timeout)
	}
	type res struct {
		conn net.Conn
		err  error
	}
	ch := make(chan res, 1)
	go func() { c, e := dialer.Dial(network, addr); ch <- res{c, e} }()
	select {
	case r := <-ch:
		if r.err == nil {
			return r.conn, nil
		}
		return net.DialTimeout(network, addr, timeout)
	case <-time.After(timeout):
		go func() {
			r := <-ch
			if r.conn != nil {
				r.conn.Close()
			}
		}()
		return nil, fmt.Errorf("warp dial timeout: %s", addr)
	}
}

func testVPNGateTCP(ip, port string) bool {
	conn, err := warpDial("tcp", net.JoinHostPort(ip, port), 4*time.Second)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

func TestVPNGateOpenVPN(server VPNGateServer) (bool, int64) {
	ovpn, err := sanitizeVPNGateOpenVPNConfig(server.OpenVPNConfig)
	if err != nil || !commandExists("openvpn") {
		return false, -1
	}

	tmp, err := os.CreateTemp("", "vpngate-check-*.ovpn")
	if err != nil {
		return false, -1
	}
	configPath := tmp.Name()
	defer os.Remove(configPath)
	if _, err := tmp.WriteString(ovpn); err != nil {
		tmp.Close()
		return false, -1
	}
	if err := tmp.Close(); err != nil {
		return false, -1
	}

	ctx, cancel := context.WithTimeout(context.Background(), 18*time.Second)
	defer cancel()

	start := time.Now()
	writer := &openVPNLogWriter{}
	cmd := exec.CommandContext(ctx, "openvpn", "--config", configPath, "--route-nopull", "--auth-nocache", "--verb", "3", "--connect-retry-max", "1", "--connect-timeout", "8")
	cmd.Stdout = writer
	cmd.Stderr = writer
	if err := cmd.Start(); err != nil {
		return false, -1
	}

	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	ticker := time.NewTicker(300 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			if writer.contains("Initialization Sequence Completed") {
				ms := time.Since(start).Milliseconds()
				cancel()
				<-done
				return true, ms
			}
		case <-done:
			if writer.contains("Initialization Sequence Completed") {
				return true, time.Since(start).Milliseconds()
			}
			return false, -1
		case <-ctx.Done():
			<-done
			return false, -1
		}
	}
}

func testVPNGateOpenVPN(server VPNGateServer) (bool, int64) {
	return TestVPNGateOpenVPN(server)
}

func measureVPNGateHTTPLatency(ip string) int64 {
	for _, port := range []string{"80", "443", "8080"} {
		start := time.Now()
		conn, err := warpDial("tcp", net.JoinHostPort(ip, port), 5*time.Second)
		if err == nil {
			conn.Close()
			return time.Since(start).Milliseconds()
		}
	}
	return -1
}

func pingVPNGateIP(ip string) int64 {
	args := []string{"-c", "1", "-W", "1", ip}
	if runtime.GOOS == "windows" {
		args = []string{"-n", "1", "-w", "1000", ip}
	}
	cmd := exec.Command("ping", args...)
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		return -1
	}
	matches := vpnGateMSRegex.FindStringSubmatch(out.String())
	for _, match := range matches[1:] {
		if match == "" {
			continue
		}
		n, err := strconv.ParseInt(match, 10, 64)
		if err == nil {
			return n
		}
	}
	return -1
}
