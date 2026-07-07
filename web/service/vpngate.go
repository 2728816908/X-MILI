package service

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/mhsanaei/3x-ui/v2/config"
	"github.com/mhsanaei/3x-ui/v2/logger"
)

type VPNGateService struct{}

const (
	vpnGateAPIURL          = "https://www.vpngate.net/api/iphone/"
	vpnGateCacheTTL        = 5 * time.Minute
	vpnGateMaxServers      = 100
	vpnGatePoolMaxServers  = 200
)

type VPNGateServer struct {
	HostName          string `json:"hostName"`
	IP                string `json:"ip"`
	CountryLong       string `json:"countryLong"`
	CountryShort      string `json:"countryShort"`
	CountryShortLower string `json:"countryShortLower"`
	NumSessions       int64  `json:"numSessions"`
	ISP               string `json:"isp"`
	ASN               string `json:"asn"`
	IPType            string `json:"ipType"`
	LocalPing         int64  `json:"localPing"`
	Proto             string `json:"proto"`
	Port              string `json:"port"`
	OpenVPNConfig     string `json:"openVPNConfig"`
	HttpLatency       int64  `json:"httpLatency"`
	CountryLongZH    string `json:"countryLongZH"`
}

var vpnGateCache struct {
	sync.Mutex
	servers []VPNGateServer
	expires time.Time
}

func (s *VPNGateService) ListServers(refresh bool) ([]VPNGateServer, error) {
	return s.ListServersWithUnavailable(refresh, false)
}

func (s *VPNGateService) ListServersWithUnavailable(refresh bool, includeUnavailable bool) ([]VPNGateServer, error) {
	vpnGateCache.Lock()
	defer vpnGateCache.Unlock()

	if !refresh && time.Now().Before(vpnGateCache.expires) {
		if includeUnavailable {
			return cloneVPNGateServers(vpnGateCache.servers), nil
		}
		return cloneVPNGateServers(filterVPNGateAvailable(vpnGateCache.servers)), nil
	}

	previousPool := mergeVPNGateServerPool(vpnGateCache.servers, loadVPNGateServerPool())
	servers, err := loadVPNGateServers()
	if err != nil {
		if len(previousPool) == 0 {
			return nil, err
		}
		vpnGateCache.servers = previousPool
		vpnGateCache.expires = time.Now().Add(vpnGateCacheTTL)
		if includeUnavailable {
			return cloneVPNGateServers(vpnGateCache.servers), nil
		}
		return cloneVPNGateServers(filterVPNGateAvailable(vpnGateCache.servers)), nil
	}
	vpnGateCache.servers = mergeVPNGateServerPool(previousPool, servers)
	vpnGateCache.expires = time.Now().Add(vpnGateCacheTTL)
	saveVPNGateServerPool(vpnGateCache.servers)

	lastFetchTimeMutex.Lock()
	lastFetchTime = time.Now()
	lastFetchTimeMutex.Unlock()

	if includeUnavailable {
		return cloneVPNGateServers(vpnGateCache.servers), nil
	}
	return cloneVPNGateServers(filterVPNGateAvailable(vpnGateCache.servers)), nil
}

func loadVPNGateServers() ([]VPNGateServer, error) {
	servers, err := (VPNGateFetcher{}).Fetch()
	if err != nil {
		return nil, err
	}
	servers = (VPNGateValidator{}).Validate(servers)
	sortVPNGateServers(servers)

	return servers, nil
}

func sortVPNGateServers(servers []VPNGateServer) {
	sort.Slice(servers, func(i, j int) bool {
		pi, pj := servers[i].LocalPing, servers[j].LocalPing
		if pi == -1 && pj == -1 {
			return servers[i].NumSessions > servers[j].NumSessions
		}
		if pi == -1 {
			return false
		}
		if pj == -1 {
			return true
		}
		if pi != pj {
			return pi < pj
		}
		return servers[i].NumSessions > servers[j].NumSessions
	})
}

func cloneVPNGateServers(servers []VPNGateServer) []VPNGateServer {
	clone := make([]VPNGateServer, len(servers))
	copy(clone, servers)
	return clone
}

func limitVPNGateServers(servers []VPNGateServer, limit int) []VPNGateServer {
	if limit <= 0 || len(servers) <= limit {
		return servers
	}
	return servers[:limit]
}

func mergeVPNGateServerPool(previous []VPNGateServer, fresh []VPNGateServer) []VPNGateServer {
	merged := make([]VPNGateServer, 0, len(fresh)+len(previous))
	seen := make(map[string]struct{}, len(fresh)+len(previous))

	for _, server := range fresh {
		key := vpnGateServerKey(server)
		if key == "" {
			continue
		}
		seen[key] = struct{}{}
		merged = append(merged, server)
	}

	for _, server := range previous {
		if !isVPNGateServerAvailable(server) {
			continue
		}
		key := vpnGateServerKey(server)
		if key == "" {
			continue
		}
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		merged = append(merged, server)
	}

	sortVPNGateServers(merged)
	return limitVPNGateServers(merged, vpnGatePoolMaxServers)
}

func vpnGateServerKey(server VPNGateServer) string {
	if server.IP == "" {
		return ""
	}
	if server.Proto != "" || server.Port != "" {
		return server.IP + "|" + server.Proto + "|" + server.Port
	}
	if server.HostName != "" {
		return server.IP + "|" + server.HostName
	}
	return server.IP
}

func isVPNGateServerAvailable(server VPNGateServer) bool {
	return server.LocalPing >= 0 || (server.OpenVPNConfig != "" && (server.Proto != "" || server.Port != ""))
}

func filterVPNGateAvailable(servers []VPNGateServer) []VPNGateServer {
	active := make([]VPNGateServer, 0, len(servers))
	for _, server := range servers {
		if isVPNGateServerAvailable(server) {
			active = append(active, server)
		}
	}
	return active
}

func (s *VPNGateService) MarkServerAvailable(server VPNGateServer, latency int64) {
	if server.IP == "" {
		return
	}
	if latency >= 0 {
		server.LocalPing = latency
	} else if server.LocalPing < 0 {
		server.LocalPing = 999999
	}

	vpnGateCache.Lock()
	defer vpnGateCache.Unlock()
	vpnGateCache.servers = mergeVPNGateServerPool(vpnGateCache.servers, []VPNGateServer{server})
	saveVPNGateServerPool(vpnGateCache.servers)
	if vpnGateCache.expires.IsZero() {
		vpnGateCache.expires = time.Now().Add(vpnGateCacheTTL)
	}
}

func vpnGateServerPoolPath() string {
	return filepath.Join(config.GetBinFolderPath(), "vpngate", "servers.json")
}

func loadVPNGateServerPool() []VPNGateServer {
	data, err := os.ReadFile(vpnGateServerPoolPath())
	if err != nil {
		return nil
	}
	var servers []VPNGateServer
	if err := json.Unmarshal(data, &servers); err != nil {
		logger.Warningf("[VPNGate] Failed to load node pool: %v", err)
		return nil
	}
	sortVPNGateServers(servers)
	return limitVPNGateServers(filterVPNGateAvailable(servers), vpnGatePoolMaxServers)
}

func saveVPNGateServerPool(servers []VPNGateServer) {
	pool := limitVPNGateServers(filterVPNGateAvailable(servers), vpnGatePoolMaxServers)
	path := vpnGateServerPoolPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		logger.Warningf("[VPNGate] Failed to create node pool dir: %v", err)
		return
	}
	data, err := json.MarshalIndent(pool, "", "  ")
	if err != nil {
		logger.Warningf("[VPNGate] Failed to marshal node pool: %v", err)
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		logger.Warningf("[VPNGate] Failed to write node pool: %v", err)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		logger.Warningf("[VPNGate] Failed to replace node pool: %v", err)
	}
}

var (
	lastFetchTime      time.Time
	lastFetchTimeMutex sync.Mutex
)

func CheckAndRefreshVPNGate(intervalMinutes int) {
	lastFetchTimeMutex.Lock()
	defer lastFetchTimeMutex.Unlock()

	// Initial load if lastFetchTime is zero
	if lastFetchTime.IsZero() || time.Since(lastFetchTime) >= time.Duration(intervalMinutes)*time.Minute {
		lastFetchTime = time.Now() // Set immediately to prevent duplicate runs
		// Fetch in the background so we do not block the cron scheduler
		go func() {
			logger.Info("[VPNGate] Background periodic node fetching started...")
			vpngateService := &VPNGateService{}
			_, err := vpngateService.ListServers(true) // force refresh and cache
			if err != nil {
				logger.Errorf("[VPNGate] Background periodic node fetch failed: %v", err)
				lastFetchTimeMutex.Lock()
				lastFetchTime = time.Time{} // reset on failure to retry on next check
				lastFetchTimeMutex.Unlock()
			} else {
				logger.Info("[VPNGate] Background periodic node fetch completed successfully.")
			}
		}()
	}
}

func (s *VPNGateService) ClearCache() {
	vpnGateCache.Lock()
	defer vpnGateCache.Unlock()
	vpnGateCache.servers = nil
	vpnGateCache.expires = time.Time{}
	_ = os.Remove(vpnGateServerPoolPath())
}
